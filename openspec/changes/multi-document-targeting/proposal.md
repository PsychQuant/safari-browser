## Why

`safari-browser` 目前所有 AppleScript 都 hard-code 到 `current tab of front window`，無法指定目標 document/tab/window。這在多視窗環境下造成三個具體問題：

1. **#17（bug）**：預設 target 行為依賴 Safari 的 z-order，與使用者視覺預期脫節。使用者看到 Plaud Web，但 `front window` 可能指向 Claude OAuth window，導致 `get url`、`js`、`upload` 全部打到錯誤頁面，且無聲失敗。
2. **#18（feature）**：沒有任何 override 機制（`--url`/`--tab`/`--window`）讓使用者明確指定目標，只能在動作前手動把 Safari 切到前景。
3. **#21（bug）**：當前一個 `upload` 留下 modal file dialog sheet 時，Safari 的 `front window` AppleScript dispatcher 會被 modal 阻塞，連 `get url` 都無限卡住。直接用 `osascript ... get URL of document 1` 卻是立即回應 — 這決定性地證明**document-scoped 存取**繞過 window-level modal block。

三個 issue 根源相同：**缺少 document-level 的目標抽象**。三者應該在同一個 architectural 改動裡解決，因為 document targeting 同時是 #18 的 feature、#17 的 fix 策略，也是 #21 繞過 modal block 的技術基礎。

## What Changes

- **新增** `SafariBridge.TargetDocument` 型別，支援四種 target 策略：`.frontWindow`（預設）、`.windowIndex(Int)`、`.urlContains(String)`、`.documentIndex(Int)`
- **新增** `SafariBridge.resolveDocumentReference(_:) -> String` helper，根據 `TargetDocument` 產生對應的 AppleScript document reference（例如 `first document whose URL contains "plaud"`）
- **改寫** `SafariBridge` 所有 AppleScript 生成函式（`openURL`, `doJavaScript`, `getCurrentURL`, `getCurrentTitle`, `getCurrentText`, `getCurrentSource`, `listTabs`, `switchToTab` 等）接受 `target: TargetDocument = .frontWindow` 參數
- **改為 document-scoped targeting**（繞過 #21 modal block）：`getCurrentURL` / `getCurrentTitle` / `getCurrentText` / `getCurrentSource` 的實作從 `current tab of front window` 改為 `document X`（透過 TargetDocument 解析）— read-only 操作改用 document 層 query，不受 modal sheet 阻塞
- **新增** 全域 CLI flags：`--url <pattern>` / `--tab <n>` / `--window <n>` / `--document <n>`（互斥，同時傳多個 → `ValidationError`）
- 所有 Commands（Get/Open/JS/Click/Upload/PDF/Screenshot/...）支援透傳 target override
- **新增** `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`：找不到符合 target 的 document 時列出所有 documents 的 URL 讓使用者選
- **新增** `safari-browser documents` subcommand 列出所有 documents 的 index / URL / title（debug/discovery 用）
- **BREAKING**: `front window` 預設行為**維持不變**（避免既有腳本壞掉），但建議新腳本明確用 `--url`。Help text 與 README 強調多視窗推薦 pattern
- **文件化** 在 README、CLAUDE.md、CHANGELOG：多視窗場景的建議 workflow

## Non-Goals

- **不改 `front window` 預設行為**：維持現狀保證向後相容，既有腳本不會壞
- **不處理 modal sheet 的 auto-dismiss**：只用 document-scoped targeting **繞過** modal block 的後果，不嘗試自動關掉 modal（那會違反 non-interference 原則 — 使用者如果真的有合法的 modal 要處理，自動 dismiss 反而破壞）
- **不做 regex / glob matching**：`--url` 用 substring 比對（最直覺、幾乎不會誤判 Plaud vs Claude）。Regex 會引進多餘複雜度且邊界情況難處理
- **不支援跨 Safari instance targeting**：假設單一 Safari.app，不處理 TestFlight / beta 等多 instance 的情境
- **不做 tab focus 改變**：`--tab` / `--window` 純指定 target，**不觸發 activate / 切換焦點**（符合 non-interference 原則）
- **不處理 Safari Private Browsing windows 的特殊語意**：private window 的 documents 理論上能被 AppleScript 列出，但如果 Safari 隱藏就隱藏（不 workaround）

## Capabilities

### New Capabilities

- `document-targeting`: 跨 commands 的 document 目標選擇抽象（`TargetDocument` 型別、`resolveDocumentReference` helper、CLI flags、錯誤路徑）
- `document-listing`: `safari-browser documents` subcommand — 列出所有 Safari documents 的 index/URL/title 供使用者探索

### Modified Capabilities

- `navigation`: `open` 指令支援 `--url` / `--tab` / `--window` / `--document` override
- `tab-management`: `tabs` / `switch-tab` 支援 window override（`--window n`）
- `page-info`: `get url` / `get title` / `get text` / `get source` 支援 target override，且預設從 `current tab of front window` 改為 document-scoped query（繞過 #21 modal block）
- `js-execution`: `js` / `js --file` 支援 target override
- `element-interaction`: `click` / `fill` / `hover` / `select` / `press` / `type` / `dblclick` / `drag` / `scroll-into-view` / `focus` 支援 target override
- `element-query`: `find` / `get html` / `get value` / `get attr` / `get count` / `get box` 支援 target override

**Transparent pass-through commands**: 其他 commands（例如 screenshot / file upload / pdf export / storage management / ref resolution / wait / extra interaction / extended element ops / find elements / keyboard / drag and drop / media settings / debug tools / reply tool / snapshot-page / the snapshot command）會透明繼承 `document-targeting` 的 CLI flags（因為它們底層呼叫 `SafariBridge` 的 AppleScript getter），但它們的 capability-level behavior 規範沒有語意變化 — 所以不列為 Modified Capabilities，避免 spec 冗餘。`document-targeting` spec 的條文會明確說明「所有 commands 繼承此 targeting 行為」。

## Impact

- **Affected specs**: 新增 `document-targeting`、`document-listing` 兩個 capability；modified 名單見上
- **Affected code**:
  - `Sources/SafariBrowser/SafariBridge.swift` — 核心（新型別、resolveDocumentReference、所有 AppleScript getter/setter）
  - `Sources/SafariBrowser/SafariBrowser.swift` — 全域 CLI flags 註冊
  - `Sources/SafariBrowser/Commands/*.swift` — 30+ 個 command 檔案都要透傳 target
  - `Sources/SafariBrowser/Utilities/Errors.swift` — `documentNotFound` 新 error case
  - 新增 `Sources/SafariBrowser/Commands/DocumentsCommand.swift` — `documents` subcommand
- **Affected tests**:
  - `Tests/SafariBrowserTests/SafariBridgeTargetTests.swift`（新）— `TargetDocument` 解析、`resolveDocumentReference` 各分支
  - `Tests/SafariBrowserTests/CommandParsingTests.swift` — 全域 flags parsing、互斥檢查
  - `Tests/SafariBrowserTests/ErrorsTests.swift` — `documentNotFound` description
- **Affected users**:
  - 多視窗使用者：獲得可靠的 target override 能力
  - 單視窗使用者：無行為變更（`front window` 預設）
  - 既有腳本：維持相容；新腳本建議明確 `--url`
- **Dependencies / infra**: 無新依賴；延伸 #19 的 `SafariBrowserError` + `runShell` 基礎
- **Resolves**: #17, #18, #21
