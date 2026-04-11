## 1. 基礎設施 — TargetDocument 型別設計

- [x] 1.1 在 `SafariBridge.swift` 新增 `TargetDocument` enum（四個 case：`frontWindow` / `windowIndex(Int)` / `urlContains(String)` / `documentIndex(Int)`），conform `Sendable` — 實作 design decision #1 "TargetDocument 型別設計"
- [x] 1.2 [P] 在 `SafariBridge.swift` 實作 "Document reference resolution" helper `resolveDocumentReference(_:)` — 對應 design decision #2 "AppleScript Document Reference 生成"，利用既有的 `escapedForAppleScript` 處理 URL pattern
- [x] 1.3 [P] 在 `Utilities/Errors.swift` 新增 `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])` case，實作「錯誤路徑：documentNotFound with list」與 spec "Document not found surfaces discoverable error" — description 須列出所有 available documents
- [x] 1.4 [P] 新增 Tests `SafariBridgeTargetTests.swift`：TDD 驗證 `resolveDocumentReference` 四個 case 產出正確 AppleScript reference，且 URL pattern 被正確 escape

## 2. CLI Flags — 全域 Target document selection via CLI flags

- [x] 2.1 在 `Commands/` 下新增 `TargetOptions.swift`（`ParsableArguments`），實作 "Target document selection via CLI flags"：包含 `--url` / `--window` / `--tab` / `--document` 四個 `@Option`，對應 design decision #4 "CLI Flags 位置：global vs per-command"
- [x] 2.2 [P] `TargetOptions.validate()` 檢查互斥：同時設超過一個 flag 拋 `ValidationError`
- [x] 2.3 [P] `TargetOptions.resolve() -> TargetDocument` 把 flags 轉成 `TargetDocument`；未設 flag 時回傳 `.frontWindow`
- [x] 2.4 [P] `TargetOptions` 型別就位，subcommands 在 Phase 5-8 wire-up 時透過 `@OptionGroup` 引用
- [x] 2.5 [P] `CommandParsingTests.swift` 新增測試：單一 flag parse 正確、多 flag 組合被 `ValidationError` 擋下、預設值等於 `.frontWindow`

## 3. SafariBridge Read-only Getters — 預設行為：`document 1` vs `current tab of front window`

- [x] 3.1 `SafariBridge.doJavaScript(...)` 接受 `target: TargetDocument = .frontWindow` 參數，AppleScript 從 `current tab of front window` 改為 `<resolved document reference>`，對應 design decision #3「預設行為：`document 1` vs `current tab of front window`」與 decision #5 "Read-only 優先改用 document-scoped，write/keystroke 仍用 window-scoped"
- [x] 3.2 `SafariBridge.doJavaScriptLarge(...)` 同上參數化，支援 target；所有 chunks 從同一 document 讀取
- [x] 3.3 [P] `SafariBridge.getCurrentURL(target:)` 改用 `URL of <document ref>` — 對應 page-info "Get current URL"
- [x] 3.4 [P] `SafariBridge.getCurrentTitle(target:)` 改用 `name of <document ref>` — 對應 page-info "Get page title"
- [x] 3.5 [P] `SafariBridge.getCurrentText(target:)` 改用 `text of <document ref>` — 對應 page-info "Get page text"
- [x] 3.6 [P] `SafariBridge.getCurrentSource(target:)` 改用 `source of <document ref>` — 對應 page-info "Get page source"
- [ ] 3.7 [P] 驗證這些 getter 在 front window 有 modal sheet 時不會 hang — 對應 spec "Read-only query bypasses window-level modal blocks"（手動驗證，留到 Phase 13）

## 4. Window-scoped Operations 保留 front-window 語意

- [ ] 4.1 `SafariBridge.listTabs(window:)` 支援 `window` 參數預設 front window，對應 tab-management "List all tabs"
- [ ] 4.2 [P] `SafariBridge.switchToTab(index:window:)` 支援 `window` 參數，對應 tab-management "Switch to tab by index"
- [ ] 4.3 [P] `SafariBridge.openNewTab(window:)` 支援 `window` 參數，對應 tab-management "Open new empty tab"
- [ ] 4.4 [P] `SafariBridge.openURL(_:target:)` 支援 target override（透過 `do JavaScript "location.href=..." in <doc ref>`），對應 navigation "Open URL in current tab"
- [ ] 4.5 [P] `SafariBridge.openURLInNewTab(_:window:)` 支援 `window` 參數，對應 navigation "Open URL in new tab"

## 5. Commands Wire-up — Get / Open / JS

- [ ] 5.1 `GetCommand` 的 `GetURL` / `GetTitle` / `GetText` / `GetSource` 加 `@OptionGroup var target: TargetOptions`，透傳到 SafariBridge
- [ ] 5.2 [P] `GetCommand` 的 `GetHTML` / `GetValue` / `GetAttr` / `GetCount` / `GetBox` 同樣透傳 target，實作 element-query "Element query commands honor document targeting"
- [ ] 5.3 [P] `OpenCommand` 加 `@OptionGroup target`；`--new-tab` 的情境 reject 非 `--window` 的 flags（對應 navigation "Open URL in new tab" scenario）
- [ ] 5.4 [P] `JSCommand` 加 `@OptionGroup target`，透傳到 `SafariBridge.doJavaScript(_:target:)`，對應 js-execution "Execute inline JavaScript" / "Execute JavaScript from file"

## 6. Commands Wire-up — Element Interaction

- [ ] 6.1 `ClickCommand` / `FillCommand` / `TypeCommand` / `SelectCommand` / `HoverCommand` / `DblclickCommand` 透傳 target，實作 element-interaction "Element interaction commands honor document targeting"
- [ ] 6.2 [P] `ScrollCommand` / `ScrollIntoViewCommand` 透傳 target
- [ ] 6.3 [P] `PressCommand` / `FocusCommand` / `DragCommand` 透傳 target
- [ ] 6.4 [P] `FindCommand` 透傳 target（共用 element-query 語意）

## 7. Tab-management Commands Wire-up

- [ ] 7.1 `TabsCommand` 加 `@OptionGroup target`；reject `--url` / `--tab` / `--document`，只接受 `--window`，對應 tab-management "List all tabs" 的 rejection scenario
- [ ] 7.2 [P] `TabCommand`（switch）同樣只接受 `--window`，對應 tab-management "Switch to tab by index"
- [ ] 7.3 [P] `TabCommand` 的 `new` 子命令只接受 `--window`，對應 tab-management "Open new empty tab"

## 8. 其他 Commands — Transparent Pass-through

- [ ] 8.1 `ScreenshotCommand` / `PdfCommand` / `UploadCommand` 加 `@OptionGroup target`（透明透傳，但文件化）— keystroke/window 操作維持 front-window
- [ ] 8.2 [P] `SnapshotCommand` / `SnapshotPageCommand` 透傳 target
- [ ] 8.3 [P] `CookiesCommand` / `StorageCommand` / `ConsoleCommand` 透傳 target（都是 read-only，可走 document-scoped）
- [ ] 8.4 [P] `WaitCommand` / `ReloadCommand` / `BackCommand` / `ForwardCommand` / `CloseCommand` / `ErrorsCommand` / `HighlightCommand` / `SetCommand` 透傳 target

## 9. Document discovery：`documents` subcommand

- [ ] 9.1 新增 `Sources/SafariBrowser/Commands/DocumentsCommand.swift`，實作 document-listing "List all Safari documents"，對應 design decision #6「Document discovery：`documents` subcommand」
- [ ] 9.2 [P] `DocumentsCommand` 支援 `--json` flag，實作 document-listing "Machine-readable JSON output"
- [ ] 9.3 [P] `DocumentsCommand` 處理空 Safari 狀態（無 windows）不 throw，實作 document-listing "Empty Safari state"
- [ ] 9.4 [P] 確保 `DocumentsCommand` 輸出格式與 `SafariBrowserError.documentNotFound` 的 `availableDocuments` 列表一致，實作 document-listing "Discovery aid for documentNotFound errors"
- [ ] 9.5 [P] 把 `DocumentsCommand` 註冊到 `SafariBrowser.swift` 的 subcommands 清單

## 10. Backward Compatibility 驗證

- [ ] 10.1 確認所有 SafariBridge public API 的新 `target:` 參數都有 `.frontWindow` 預設值，對應 document-targeting "Backward compatibility with existing scripts"
- [ ] 10.2 [P] `grep` 確認 `Sources/` 沒有任何殘留的 `current tab of front window`（除了明確保留 keystroke/window 操作的地方）
- [ ] 10.3 [P] 新增測試 `testSingleWindowDefaultMatchesLegacy`：在模擬單視窗環境下，預設 `get url` 行為與舊版 `current tab of front window` 一致

## 11. 測試

- [ ] 11.1 `SafariBridgeTargetTests.swift` 覆蓋 `TargetDocument` 解析所有 case，含 URL 含特殊字元的 escape
- [ ] 11.2 [P] `CommandParsingTests.swift` 新增 `TargetOptions` 互斥驗證、各 subcommand 的 target 繼承測試
- [ ] 11.3 [P] `ErrorsTests.swift` 新增 `testDocumentNotFound`：驗證 description 包含 pattern + availableDocuments 列表
- [ ] 11.4 [P] 新增整合測試 mock 多 document 環境，驗證 `--url` / `--window` / `--document` 各自 route 到正確 document
- [ ] 11.5 [P] 新增 modal sheet bypass 測試：驗證 read-only query 在 front window 有 sheet 時仍 return

## 12. 文件

- [ ] 12.1 `README.md` 新增「Multi-window scenarios」段落，示範 `--url` 用法
- [ ] 12.2 [P] `CHANGELOG.md` `Unreleased` 區塊新增完整 #17 / #18 / #21 解決的描述，含 Migration Plan 的 subtle behavior change 說明
- [ ] 12.3 [P] `CLAUDE.md` 更新 safari-browser plugin 指引，建議 AI agents 在多視窗環境用 `--url` 明確 target
- [ ] 12.4 [P] 在 `README.md` 新增 `documents` subcommand 使用範例

## 13. 最終驗證 — Risks / Trade-offs 確認

- [ ] 13.1 手動測試：單視窗環境 `safari-browser get url` 行為不變（對應 design risk #1 的 mitigation）
- [ ] 13.2 [P] 手動測試：多視窗環境 `safari-browser --url plaud get url` 指向正確 document，`safari-browser documents` 列出所有 documents
- [ ] 13.3 [P] 手動測試：重現 #21 — 啟動一個 upload 卡在 modal sheet，同時跑 `safari-browser get url`，確認能立即回傳（不 hang）
- [ ] 13.4 [P] 手動測試：錯誤路徑 — `safari-browser --url typo get url` 產生 `documentNotFound` 並列出所有可用 documents
- [ ] 13.5 [P] 跑完整測試套件 `swift test`（#22 之後預設 skip E2E，不干擾 Safari）確認 0 regression
- [ ] 13.6 [P] 執行 `/issue-driven-dev:idd-verify` 對應的 root issues（#17 / #18 / #21）— 每個 issue 跑一次 6-AI verify 確認原 findings 全部解決
