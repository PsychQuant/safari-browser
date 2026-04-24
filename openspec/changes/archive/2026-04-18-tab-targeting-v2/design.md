## Context

Issue #28 reporter 在執行 `/plaud-upload` 時，連續踩到 6 個 `--url` tab locking 的 reliability gap：`documents` 和 `upload --native` 對同一個 Plaud session 回報不同 tab 數、同 URL 雙 tab 無法 disambiguation、`close --url` 把兩個 Plaud tab 一起殺掉、`open` 「累積」假 tab、`js` 和 `upload --native` 對 ambiguous match 一個 silent first-match 一個 fail-closed、`upload --native` 失敗後 Plaud modal orphaned。

Diagnosis（issue #28 comment 2026-04-17）找出 root cause：codebase 並存兩個觀察不同 Safari 抽象的 resolver：

- **JS-path resolver**：`SafariBridge.resolveDocumentReference` (line 58–70) 對應 AppleScript `first document whose URL contains "..."`。查的是 Safari 的 `documents` collection —— **每個 window 只有一個 document**（front tab）。用於 `js` / `open` / `getters` / `storage` / `wait` / `snapshot`。
- **Native-path resolver**：`SafariBridge.pickNativeTarget` (line 402–509) 走 `listAllWindows` 完整 enumerate `tabs of windows`。觀察到所有 window 的所有 tab。Multi-match fail-closed 於 `ambiguousWindowMatch`。用於 `upload --native` / `close`。

`DocumentsCommand` 使用 `listAllDocuments` (line 321–354)，本質和 JS-path 同源（iterate `documents` collection），所以 `safari-browser documents` 顯示的是 JS-path 視圖——這就是為什麼 reporter 看到 `documents` 回報 1 個 Plaud tab、`upload --native` 卻說有 2 個。

同時，這次 discussion 提出一個更根本的問題：safari-browser 一直沒有正式表達的設計哲學「模擬人類使用 Safari 的方式」，應該提上 principle 層級。人類看 Safari 只看 tab bar（= `tabs of windows`），從不思考 `documents` 是什麼；人類看到兩個相同 tab 會停下來問「哪個才對」；人類輸入已開過的網址，瀏覽器會 focus 不會重開。所有 6 個症狀都是「程式模型偏離人類模型」的徵兆。

這個 change 同時處理兩件事：**架構層面** 收斂 resolver 到 Native-path；**原則層面** 將 human-emulation 提升為 principle 並與既有 non-interference principle 建立邊界協調機制。

## Goals / Non-Goals

**Goals:**

- 廢除雙 resolver 架構，所有 `@OptionGroup var target: TargetOptions` 的 command 共用一個 resolver（Native-path）
- 建立 `human-emulation` principle 作為 cross-cutting design principle，與 `non-interference` 同級，提供後續所有 command 的預設行為指南
- 解決 issue #28 的 6 個具體 reliability gap
- 提供 same-URL tab 的結構化 addressing 機制（`--window N --tab-in-window M`）
- 統一 `.urlContains` 的 fail-closed 語意並提供 `--first-match` opt-in
- 改 `open` 預設行為為 focus-existing，用 spatial gradient 協調 non-interference

**Non-Goals:**

- 不重寫 Safari AppleScript bridge 的其他部分（如 keystroke dispatch、Accessibility API 整合 —— 保留 #23 / #26 既有設計）
- 不碰 channel server、vision worker、snapshot 等 higher-level feature 的實作
- 不新增 tab-id stable identifier（Safari AppleScript 不提供穩定 tab ID，此路不通）
- 不引入 daemon 架構來做 cross-CLI-call cache（50ms overhead 接受為 architectural reality）
- 不改動 `upload --native` 的 modal orphan 行為（issue #28 第 6 項 —— 留待後續獨立 change）
- 不提供 `--nth-match N` flag（`--tab-in-window` 更直覺、更符合人類空間模型）
- 不做完整 Cross-Space detection 的授權流程（若 screen recording 權限未授予，fallback 到保守行為即可）

## Decisions

### Decision: Resolver convergence to tabs-of-windows

**決策**：所有 target resolution 統一走 Native-path `resolveNativeTarget` (SafariBridge.swift:519)。JS-path `resolveDocumentReference` (line 58) 降級為 thin compatibility wrapper，內部轉呼叫 Native-path 並抽出 resolved window/tab index 組回 AppleScript 引用字串；或直接廢除，把所有 caller 改成以 `(window, tab)` 座標組出 AppleScript 引用。

**Rationale**：Native-path 看到的 `tabs of windows` 就是人類看到的 tab bar。收斂到這個視圖才能讓 `documents` / `upload --native` / `close` 對「有幾個 X tab」給出一致答案。保留 compatibility wrapper 使既有 callers（JSCommand、GetCommand、StorageCommand、WaitCommand、SnapshotCommand、OpenCommand）的最小差異改動就能收斂；wrapper 在後續 minor version 可以完全移除。

**Alternatives considered**：

- *保留雙 resolver，用 documentation 解釋差異*：這是目前狀態，issue #28 證明這個解法失敗 —— user 沒人會讀 doc 去理解 `documents` collection 是什麼。此路駁回。
- *所有 callers 直接改用 `resolveNativeTarget` 不做 wrapper*：最乾淨但改動範圍大（~10 個 command files），一次 PR 風險高。選擇漸進路線：先做 wrapper，後續 minor version 再逐步 refactor callers。

### Decision: Composite targeting flag --tab-in-window

**決策**：新增 `--tab-in-window N` flag，**必須** 與 `--window M` 同時出現（`--tab-in-window` 單獨出現 → validation error）。對應新增 `TargetDocument.windowTab(window: Int, tabInWindow: Int)` case。此為 same-URL tab 的結構化逃生艙。

**Rationale**：人類分辨同 URL 雙 tab 的心智模型是「第 2 個 window 的第 3 個 tab」—— window + tab-in-window 座標。此組合語義清楚、符合 tab bar 視覺佈局。`--tab-in-window` 必須 pair `--window`，因為「某 window 內的第 N tab」在不指定哪個 window 時無意義。

**Alternatives considered**：

- *`--nth-match N`*：搭配 `--url` 接受第 N 個 match。缺點：匹配順序依賴 enumeration 順序，對人類不透明；換個 Safari 版本或 window 順序變了就會選錯 tab。駁回。
- *`--tab-id <safari-id>`*：Safari AppleScript 沒有穩定 tab identifier（`id of tab` 存在但會在 tab 關閉/移動時失效）。駁回。
- *`--document N` 輸出完整 tab-in-window 語意*：對既有 `--document` 用法 breaking change 過大，且會破壞「全局 document 序號」的線性語義。不採用。

### Decision: Deprecate --tab alias

**決策**：`--tab N` 目前是 `--document N` 的 alias（TargetOptions.swift:30 註解「Alias for --document; kept for browser-automation familiarity」），但在新 tab bar 模型下，「tab」應該專指「某 window 內的 tab」而非「全局 document 序號」。Deprecation plan：

- v2.5（此 change）：`--tab` 仍接受舊語義，但發出 stderr deprecation warning（「`--tab` alias 將在 v3.0 移除，請改用 `--document` 或 `--tab-in-window`」）
- v3.0：完全移除 `--tab` flag

**Rationale**：`--tab` 這個名字會讓新使用者以為是「某 window 的第 N tab」—— 這正是 `--tab-in-window` 的語義。同時讓 `--tab` 表示「全局 document index」和「window 內 tab index」兩種意義會造成文檔與錯誤訊息的永久混亂。

### Decision: Open default change to focus-existing

**決策**：`safari-browser open <url>` 的預設行為改為：

1. 如果有任何 tab 的 URL 精確匹配 `<url>` → **focus-existing**（走 spatial gradient，見下）
2. 否則 → **new-tab**（在當前 window 的末尾）

原本「navigate front tab」行為改由 `--replace-tab` flag 顯式 opt-in。現有 `--new-tab` / `--new-window` flag 不受影響。

**Rationale**：人類按 Cmd+L 輸入已開過的網址，瀏覽器（Safari / Arc / Chrome）都會補全到既有 tab 而非新開或覆蓋當前 tab。`open <url>` 作為「打開一個網址」的 CLI primitive，應該遵循這個共通心智模型。`--replace-tab` 給需要「重置當前 tab」語義的 script 繼續使用的退路。

**Alternatives considered**：

- *保留「navigate front tab」當預設*：issue #28 第 4 項的根源，user 誤解為「累積 tab」。駁回。
- *focus-existing 但 match 只看 hostname*：太寬鬆，不同 path 的 tab 會被合併。採精確 URL match（包含 query string）。

### Decision: Unified fail-closed on urlContains ambiguity

**決策**：`.urlContains(pattern)` 在 resolver 發現多個 matching tabs 時，無論走哪條 path，都 **fail-closed** 丟 `ambiguousWindowMatch` 錯誤並列出所有 match。想要 first-match 行為必須顯式加 `--first-match` flag，並在 stderr 印 warning 列出所有 match 與實際選到哪一個。

**Rationale**：人類看到兩個相同 tab 會停下來問「哪個才對」。Silent first-match 是 issue #28 第 5 項的來源：`js --url plaud` silent 選到一個、後續 `upload --native --url plaud` fail—— user 完全看不出第一步其實選錯 tab。Fail-closed 讓歧義立刻可見。`--first-match` opt-in 讓 script 作者在知道風險時可以回退到原 behavior，且 log 留下 trace 可調試。

### Decision: Spatial gradient for focus-existing

**決策**：`open --focus-existing`（或預設 behavior 路徑）根據目標 tab 的空間關係採取不同行為：

| 目標 tab 位置 | 行為 | Interference 分類 |
|---------------|------|-------------------|
| 已在 front window 的 current tab | noop | 非干擾 |
| 同 window 的 background tab | `set current tab of window N to tab T`（tab-switch） | Passively interfering（transitively authorized） |
| 同 Space 的不同 window | `activate window N` + tab-switch if needed | Passively interfering + stderr warning |
| 跨 Space（目標 window 在不同 Space） | **不跨 Space raise**，改在當前 Space 開 new-tab | 非干擾（退回 new-tab path） |

Space 偵測透過 CGWindow API `kCGWindowWorkspace`。若 screen recording 權限未授予、API call 失敗，保守 fallback：假設目標在同 Space，走「同 Space raise」路徑（不引入新的未授權行為）。

**Rationale**：人類在多 Space 佈局下，每個 Space 代表不同任務 context（工作 / 娛樂 / chat）。Automation 從工作 Space 發起「打開 Plaud」指令，如果自動跳到娛樂 Space 裡那個舊 Plaud tab，打斷 user 的 workspace organization。跨 Space 改開 new-tab 在當前 Space 更貼近「我現在這裡要的」——與 human-emulation 一致，且自動避開 Mission Control / Stage Manager 戰爭。

**Alternatives considered**：

- *一律 raise（不分 spatial layer）*：簡單但跨 Space 體驗差。駁回。
- *新增 `--focus` opt-in flag*：太囉嗦，違背 human-emulation 的「預設就是人類直覺」精神。駁回。
- *Focus-without-raise*：AppleScript 無此能力，偽 focus 會造成 state 不一致。駁回。

### Decision: Capture human-emulation as first-class principle

**決策**：新建 `openspec/specs/human-emulation/spec.md` 作為 cross-cutting capability，與既有 `non-interference` 並列。spec 內容包含：

- Principle declaration：safari-browser 預設行為應貼近人類用 Safari 的心智模型
- 四個衍生規則：tab bar 為 ground truth、歧義 fail-closed、已開網址 focus 不重開、空間感分級互動
- 與 non-interference 的邊界條款：當兩 principle 衝突時，採空間梯度策略（同空間 raise、跨空間退回 new-tab）

**Rationale**：把預設行為的理由從「scattered 在各個 command 的 design choice」提升到「單一可查的 principle spec」。未來新 command 在分類 interference level 時，同時要對齊 human-emulation principle；當 design 在兩者間有 tension，spatial gradient 提供既有範式。這個 principle 提升了 safari-browser 的 design coherence，而不只是修 issue #28 的症狀。

## Risks / Trade-offs

- **Breaking change 廣泛**：`--tab` deprecation、`open` default 改、ambiguous first-match 統一 fail-closed，三個都會影響既有下游 skill（plaud-upload、plaud-download、潛在其他 Drive/Gmail automation）。
  → **Mitigation**：major version bump（v2 → v3），完整 migration guide 寫入 README + CHANGELOG。`--tab` deprecation 有 one version 的 warning cycle。
- **Performance overhead ~50ms/call**：每次 targeted CLI call 多一次 `listAllWindows` enumeration。
  → **Mitigation**：CLI 為 one-shot process 無 cache 可能，但 50ms 對 AI agent workflow 可接受（20 步累加 ~1s）。高頻 polling use case 應改用 channel server，不該走 per-command CLI。
- **Space detection 需要 screen recording 權限**：跨 Space behavior 依賴 CGWindow API。
  → **Mitigation**：未授予時 graceful fallback 到「同 Space raise」路徑（保守但仍符合原意）。stderr warning 告知使用者「跨 Space detection 需要額外權限」。
- **Compatibility wrapper 會留下 short-term dead weight**：JS-path resolver 即使降級為 thin wrapper 仍會在 SafariBridge.swift 存在一陣子。
  → **Mitigation**：Wrapper 明確標注 deprecation + TODO 指向 v3.1 的 remove target。降級後行為上完全等同 Native-path，不會有 bug surface。
- **`listAllDocuments` 輸出格式改變**：既有 user 解析 `documents` 輸出的腳本會 break（新欄位 `tab_in_window` 會被插入）。
  → **Mitigation**：`documents --json` 格式保留舊欄位 + 新欄位；純 text 輸出加入 new column 但排版相容（空白分隔）。CHANGELOG 明確警告 text parser 需更新。

## Migration Plan

### Rollout phases

1. **v2.5（此 change）**：
   - 導入 `--tab-in-window` / `--first-match` / `--replace-tab` 新 flags（additive，不 break）
   - `--tab` 加 deprecation warning 但仍能用
   - `open` 預設改 focus-existing（**breaking**），`--replace-tab` 提供 opt-out
   - `.urlContains` 全 path fail-closed（**breaking**），`--first-match` 提供 opt-out
   - `listAllDocuments` 基於 `listAllWindows` 輸出完整 tab 列表（**breaking** for text parser）
   - Human-emulation principle 正式成立

2. **v3.0（後續 change）**：
   - 完全移除 `--tab` alias
   - 移除 JS-path compatibility wrapper
   - 考慮統一 enumeration semantics（目前 `--document N` 語義 vs 新 `--tab-in-window` 的關係）

### Rollback

此 change 的所有 behavior 變更都在 Swift layer + spec layer，無 database / persistent state 變動。如需 rollback：

- 恢復 proposal 前的 `SafariBridge.swift` / `TargetOptions.swift` / `OpenCommand.swift` 即可
- Spec delta 透過 `spectra archive --revert` 還原
- Breaking change 的下游影響透過 `~/bin/safari-browser` 的 wrapper 自動 downgrade

### Downstream skill migration

對受影響的 skill 提供 migration guide：

| Old behavior | New behavior | Migration |
|--------------|--------------|-----------|
| `open <url>` navigate front tab | `open <url>` focus-existing → new-tab | 需要 navigate 行為改用 `open --replace-tab <url>` |
| `js --url plaud ...` silent first-match | Fail-closed on multi-match | 需要保留舊行為加 `--first-match` |
| `--tab 2` = 全局 document index 2 | 仍然是 document index 但 deprecated | 改用 `--document 2` 或 `--tab-in-window 2 --window N` |
| `documents` 輸出每 window 一行 | 輸出每 tab 一行 | Text parser 需更新欄位對應 |

## Open Questions

- **Space detection 在 Stage Manager 模式下的行為**：macOS 14+ Stage Manager 把「group」當作一種 space-like 層級，CGWindow API 是否 consistent 回報 `kCGWindowWorkspace`？需要實測驗證。若不一致，可能要加額外 heuristic。
- **`tabs` / `tab` window-level primitive 是否一併升級到 Native-path 語義**：目前它們只接受 `--window` flag。在新模型下是否允許 `--tab-in-window`？待 implementation 時決定，預設不改動（保持 window-level scope）。
- **ChannelServer 是否受影響**：Channel server 執行 command 的 routing 是否依賴 JS-path resolver？實作時需讀 channel 相關 code 確認。若依賴，一併收斂；若不依賴則無需調整。
