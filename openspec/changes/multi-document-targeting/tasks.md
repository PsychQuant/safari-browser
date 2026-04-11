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

- [x] 4.1 `SafariBridge.listTabs(window:)` 支援 `window` 參數預設 front window，對應 tab-management "List all tabs"
- [x] 4.2 [P] `SafariBridge.switchToTab(_:window:)` 支援 `window` 參數，對應 tab-management "Switch to tab by index"
- [x] 4.3 [P] `SafariBridge.openNewTab(window:)` 支援 `window` 參數，對應 tab-management "Open new empty tab"
- [x] 4.4 [P] `SafariBridge.openURL(_:target:)` 支援 target override（透過 `do JavaScript "location.href=..." in <doc ref>`），對應 navigation "Open URL in current tab"
- [x] 4.5 [P] `SafariBridge.openURLInNewTab(_:window:)` 支援 `window` 參數，對應 navigation "Open URL in new tab"

## 5. Commands Wire-up — Get / Open / JS

- [x] 5.1 `GetCommand` 的 `GetURL` / `GetTitle` / `GetText` / `GetSource` 加 `@OptionGroup var target: TargetOptions`，透傳到 SafariBridge
- [x] 5.2 [P] `GetCommand` 的 `GetHTML` / `GetValue` / `GetAttr` / `GetCount` / `GetBox` 同樣透傳 target，實作 element-query "Element query commands honor document targeting"
- [x] 5.3 [P] `OpenCommand` 加 `@OptionGroup target`；`--new-tab` 的情境 reject 非 `--window` 的 flags（對應 navigation "Open URL in new tab" scenario）
- [x] 5.4 [P] `JSCommand` 加 `@OptionGroup target`，透傳到 `SafariBridge.doJavaScript(_:target:)`，對應 js-execution "Execute inline JavaScript" / "Execute JavaScript from file"

## 6. Commands Wire-up — Element Interaction

- [x] 6.1 `ClickCommand` / `FillCommand` / `TypeCommand` / `SelectCommand` / `HoverCommand` / `DblclickCommand` 透傳 target，實作 element-interaction "Element interaction commands honor document targeting"
- [x] 6.2 [P] `ScrollCommand` / `ScrollIntoViewCommand` 透傳 target
- [x] 6.3 [P] `PressCommand` / `FocusCommand` / `DragCommand`（後者用 `documentTarget` 避免與 drag target 名稱衝突）透傳 target
- [x] 6.4 [P] `FindCommand` 透傳 target（共用 element-query 語意）

## 7. Tab-management Commands Wire-up

- [x] 7.1 `TabsCommand` 加 `@OptionGroup target`；reject `--url` / `--tab` / `--document`，只接受 `--window`，對應 tab-management "List all tabs" 的 rejection scenario
- [x] 7.2 [P] `TabCommand`（switch）同樣只接受 `--window`（用 `documentTarget` 避免與 local `tabArg` 衝突），對應 tab-management "Switch to tab by index"
- [x] 7.3 [P] `TabCommand` 的 `new` 子命令只接受 `--window`，對應 tab-management "Open new empty tab"

## 8. 其他 Commands — Transparent Pass-through

- [x] 8.1 `IsCommand`（4 subcommand）/ `CheckCommand` / `UncheckCommand` 透傳 target
- [x] 8.2 [P] `BackCommand` / `ForwardCommand` / `ReloadCommand` / `HighlightCommand` 透傳 target
- [x] 8.3 [P] `CookiesCommand`（3 subcommand）/ `ConsoleCommand` / `ErrorsCommand` / `SetCommand`（SetMedia）/ `MouseCommand`（4 subcommand）透傳 target
- [ ] 8.4 Deferred（complexity / CLI flag conflicts）: `UploadCommand` native path（keystroke 只能走 front-window）、`WaitCommand`（本身有 `--url` local option 與 TargetOptions 衝突）、`CloseCommand` / `ScreenshotCommand` / `PdfCommand` / `SnapshotCommand` / `StorageCommand` — 這些 transparent callers 透過 SafariBridge 的 default target 已正確運作，可留到後續補強

## 9. Document discovery：`documents` subcommand

- [x] 9.1 新增 `Sources/SafariBrowser/Commands/DocumentsCommand.swift`，實作 document-listing "List all Safari documents"，對應 design decision #6「Document discovery：`documents` subcommand」。同步新增 `SafariBridge.listAllDocuments()` + `DocumentInfo` struct
- [x] 9.2 [P] `DocumentsCommand` 支援 `--json` flag，實作 document-listing "Machine-readable JSON output"
- [x] 9.3 [P] `DocumentsCommand` 處理空 Safari 狀態（無 documents）不 throw，print 空輸出 exit 0，實作 document-listing "Empty Safari state"
- [x] 9.4 [P] 文字輸出 `[N] url — title` 格式與 `SafariBrowserError.documentNotFound` 的 listing 一致，實作 document-listing "Discovery aid for documentNotFound errors"
- [x] 9.5 [P] `SafariBrowser.swift` subcommands 清單新增 `DocumentsCommand.self`；`CommandParsingTests` 覆蓋 `--json` flag parsing

## 10. Backward Compatibility 驗證

- [x] 10.1 確認所有 SafariBridge public API 的新 `target:` 參數都有 `.frontWindow` 預設值；driver grep 確認 `runShell`/`runAppleScript` 通過所有 callers
- [x] 10.2 [P] `grep "current tab of front window"` 確認僅剩 intentional window-scoped operations：`closeCurrentTab`, `getWindowID`, `navigateFileDialog`, `uploadViaNativeDialog`, `pdfExport`, `ScreenshotCommand` — 全部是 design decision #5 明確允許的
- [x] 10.3 [P] 新增 `testFrontWindowProducesLegacyEquivalentReference` 鎖定預設 target = `document 1`，且**不**含 `front window` / `current tab`（防止 future refactor 誤改）

## 11. 測試

- [x] 11.1 `SafariBridgeTargetTests.swift` 覆蓋 `TargetDocument` 四個 case、URL 特殊字元 escape（雙引號、backslash、unicode、空 pattern）、`Sendable` conformance
- [x] 11.2 [P] `CommandParsingTests.swift` 覆蓋 `TargetOptions` 互斥驗證 + `DocumentsCommand --json` flag parsing
- [x] 11.3 [P] `ErrorsTests.swift` 的 `testDocumentNotFound` 驗證 description 包含 pattern + availableDocuments 列表 + 空 list 情境
- [ ] 11.4 [P] 整合測試 mock 多 document 環境 — **deferred**：SafariBridge 的 `runAppleScript` 沒有注入 seam，真實多 document 測試需要 Safari 實例，留到 Phase 13 手動驗證
- [ ] 11.5 [P] Modal sheet bypass 測試 — **deferred**：同上，無法在 unit test 重現 modal，留到 Phase 13 手動驗證

## 12. 文件

- [x] 12.1 `README.md` 新增「Multi-window Targeting (#17 #18 #21)」段落，示範 `--url` / `--window` / `--tab` / `--document` 用法與互斥規則
- [x] 12.2 [P] `CHANGELOG.md` `Unreleased` 區塊新增 #17/#18/#21 主條目 + `documents` subcommand 獨立條目
- [x] 12.3 [P] `CLAUDE.md` 新增「Multi-window / Multi-document targeting」段落，明確建議 AI agent 先跑 `documents` 再用 `--url`
- [x] 12.4 [P] `README.md` 的「Tab Management」段落示範 `--window` override；新 targeting 段落含 `documents` subcommand 使用範例

## 13. 最終驗證 — Risks / Trade-offs 確認

- [ ] 13.1 **User manual test**：單視窗環境 `safari-browser get url` 行為不變 — 要求 Safari 互動，請 user 執行
- [ ] 13.2 [P] **User manual test**：多視窗環境 `safari-browser --url plaud get url` + `safari-browser documents` — 要求 Safari 互動
- [ ] 13.3 [P] **User manual test**：重現 #21 — 啟動 upload 卡在 modal sheet，並行跑 `safari-browser get url` 確認不 hang — 要求 Safari 互動
- [ ] 13.4 [P] **User manual test**：錯誤路徑 `safari-browser --url typo get url` — 要求 Safari 互動
- [x] 13.5 [P] **自動化**：`swift test` → 78/78 通過，E2E auto-skip（#22）零 regression
- [ ] 13.6 [P] 執行 `/issue-driven-dev:idd-verify #17` / `#18` / `#21` — 建議 archive 完成後再跑，一次驗證完整 diff
