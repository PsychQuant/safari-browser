## Why

Issue #28 揭露 `--url` tab locking 有 6 個 reliability gaps —— root cause 是 codebase 並存兩個觀察不同 Safari 抽象的 resolver：JS-path `resolveDocumentReference` 查 `documents` collection（每 window 只看得到 front tab），Native-path `pickNativeTarget` 查 `tabs of windows`（完整視圖）。兩者視角不一致導致 `documents` 和 `upload --native` 對「有幾個 plaud tab」答案不同、同 URL 雙 tab 無法區分、`close --url` 多殺、`open` 累積假 tab、JS-path silent first-match vs Native-path fail-closed 語意矛盾。

這些 gap 對單純 CLI 使用者只是偶發 annoyance，但對 AI agent 自動化（plaud-upload、plaud-download、多 tab 工作流）會在單一 domain 有重複 tab 時全面變脆。

現在也是時候把 safari-browser 還沒正式表達的設計哲學提上 principle 層級：**模擬人類使用方式**（human-emulation）—— CLI 行為應該貼近人類用 Safari 的心智模型（tab bar 是唯一事實、歧義時停下來問、已開網址會 focus 不會重開）。

## What Changes

- **BREAKING** Resolver 收斂到 `tabs of windows`。`SafariBridge.listAllDocuments` 改基於 `listAllWindows`，廢除 `documents` collection 作為查詢源。所有 `@OptionGroup var target: TargetOptions` 的 command 統一走 `resolveNativeTarget`。
- **BREAKING** `--tab` flag deprecated（目前是 `--document` 的 alias，在 tab bar 模型下是誤導性命名）。Deprecation cycle：v2.5 加 warning、v3.0 移除。
- **BREAKING** `open <url>` 預設行為改為 **focus-existing → 否則 new-tab**。原本「navigate front tab」行為改由 `--replace-tab` 顯式 opt-in。
- **BREAKING** `.urlContains` 的 ambiguous match 在 JS-path 也要 fail-closed（目前 JS-path 用 AppleScript `first ... whose ...` implicit first-match）。想要 first-match 必須顯式 `--first-match`。
- **NEW flag** `--tab-in-window N`：配合 `--window M` 使用，在同一 window 內指定第 N 個 tab。同 URL 雙 tab 場景的逃生艙。
- **NEW flag** `--first-match`：opt-in 接受 `.urlContains` 多 match 時選第一個（搭配 stderr warning）。
- **NEW flag** `--replace-tab`：opt-in 回到舊 `open` 行為（navigate front tab 而非 focus-existing）。
- **NEW principle** `human-emulation`：與 `non-interference` 同級的跨切面 design principle，用 spatial gradient 解決兩者衝突。
- **NEW spatial gradient** for `open --focus-existing`：同 window background tab → tab-switch；同 Space 不同 window → raise window + stderr warning；跨 Space → 不跨 Space raise，改開 new-tab 在當前 Space。
- **MODIFY** `non-interference/spec.md` 加入 spatial gradient requirement，明確 `open` 的 focus 行為在各 spatial layer 的 interference 分類。

## Non-Goals

留待 `design.md` 的 Goals/Non-Goals 段處理。

## Capabilities

### New Capabilities

- `human-emulation`: Cross-cutting design principle。safari-browser 所有 command 的預設行為應該貼近人類用 Safari 的心智模型（tab bar 是唯一事實、歧義時 fail-closed、已開網址 focus 而非重開、空間感的互動層級）。與 `non-interference` 同級，在衝突時透過 spatial gradient 調和。

### Modified Capabilities

- `document-targeting`: 新增 `--tab-in-window` / `--first-match` / `--replace-tab` flags、廢 `--tab` alias、統一 `.urlContains` 的 fail-closed 語意、`.frontWindow` 的預設解釋。
- `document-listing`: `listAllDocuments` 改基於 `listAllWindows`，輸出語意從「每 window 的 front tab」改成「每 window 所有 tab」。
- `non-interference`: 加入 spatial gradient requirement，明確 `open --focus-existing` 在「同 window tab-switch / 同 Space raise / 跨 Space new-tab」三層的 interference 分類。
- `navigation`: `open <url>` 的預設語意從「navigate front tab」改為 focus-existing。新增 `--replace-tab` opt-in 保留舊行為。

## Impact

### Affected Specs

- NEW `openspec/specs/human-emulation/spec.md`
- MODIFY `openspec/specs/document-targeting/spec.md`
- MODIFY `openspec/specs/document-listing/spec.md`
- MODIFY `openspec/specs/non-interference/spec.md`
- MODIFY `openspec/specs/navigation/spec.md`（如不存在則 NEW）

### Affected Code

- `Sources/SafariBrowser/SafariBridge.swift`
  - `resolveDocumentReference` (line 58): deprecate 或改為 thin wrapper of Native-path
  - `listAllDocuments` (line 321): 改基於 `listAllWindows` 輸出完整 tab 列表
  - `pickNativeTarget` / `resolveNativeTarget` (line 402/519): 成為唯一 resolver
  - 新增 `TargetDocument.windowTab(window: Int, tabInWindow: Int)` case
  - 新增 Space 偵測 helper（透過 CGWindow API `kCGWindowWorkspace`，需 screen recording 權限 fallback）
- `Sources/SafariBrowser/Commands/TargetOptions.swift`
  - 新增 `--tab-in-window` / `--first-match` flags
  - `--tab` flag 加 deprecation warning
  - `validate()` 增加 `--window + --tab-in-window` 的 pair 檢查
- `Sources/SafariBrowser/Commands/OpenCommand.swift`
  - 預設 `run()` 改呼叫 focus-existing path
  - 新增 `--replace-tab` flag
- `Sources/SafariBrowser/Commands/CloseCommand.swift`
  - 確認 `close --url` ambiguous fail-closed（driven by #3 repro in issue #28）
- `Sources/SafariBrowser/Commands/JSCommand.swift` + 其他所有 `@OptionGroup var target: TargetOptions` 的 commands（GetCommand、StorageCommand、WaitCommand、SnapshotCommand 等）
  - Resolver call site 統一到 `resolveNativeTarget`
- `Sources/SafariBrowser/Commands/DocumentsCommand.swift`
  - 輸出格式加入 tab-in-window index，對應新的 `--tab-in-window` flag
- `Sources/SafariBrowser/Utilities/Errors.swift`
  - `ambiguousWindowMatch` 錯誤訊息加入 `--first-match` / `--tab-in-window` 的 suggestion
- `Tests/SafariBrowserTests/`
  - 新增 resolver convergence tests、spatial gradient tests、deprecation warning tests

### Affected External Integrations

- `plaud-transcriber` skill 可能依賴 `open` replace-tab 行為，需要 migration guide
- 其他下游 skill 凡呼叫 `safari-browser open <url>` 且假設「navigate front tab」語意的都會 break，deprecation warning 先引導 → `--replace-tab` 遷移
- `~/bin/safari-browser` 透過 GitHub Release 分發，breaking change 需 major version bump（v2 → v3）
