## 1. Resolver 核心（SafariBridge 層）

- [x] 1.1 新增 `SafariBrowserError.ambiguousWindowMatch(pattern:matches:)` case 到 `Sources/SafariBrowser/Utilities/Errors.swift`，錯誤描述列出每個 match 的 window index 與 URL（對應 spec requirement「Window ambiguity surfaces deterministic error」和 design decision: Multi-match fail-closed with `ambiguousWindowMatch` error）
- [x] 1.2 在 `Tests/SafariBrowserTests/ErrorsTests.swift` 寫 `ambiguousWindowMatch` 的錯誤 description 測試，確認訊息包含 pattern、所有 match 的 URL 與 window index、以及建議更具體 substring 的提示（error description test 歸 ErrorsTests，CommandParsingTests 只管 command parse/validate）
- [x] 1.3 在 `Tests/SafariBrowserTests/WindowIndexResolverTests.swift` 新增完整 resolver 測試覆蓋（18 個測試）：`.frontWindow → window 1 / no switch`、`.windowIndex(n) in-range / out-of-range / zero`、`.documentIndex(n) mapping to owning window current/background tab / out-of-range`、`.urlContains("plaud") single current / single background / no match / multi-match fail-closed / same-window multi-match / more-specific substring disambiguates`、parser empty / single / multiple / malformed(對應「Native path URL resolution to window index」requirement)
- [x] 1.4 在 `Sources/SafariBrowser/SafariBridge.swift` 實作 `static func pickNativeTarget(_:in:)` 作為 pure resolver 核心、`resolveNativeTarget(from:) async throws -> ResolvedWindowTarget` 作為 async orchestrator、`listAllWindows() async throws -> [WindowInfo]` 單一 AppleScript roundtrip enumeration（GS/RS 分隔）、`parseWindowEnumeration(_:)` 公開 parser（對應 design decision: `SafariBridge.resolveWindowIndex(from: TargetDocument) -> Int` 作為統一 resolver）
- [x] 1.5 確認 resolver 是 stateless — 無 process-local cache、`resolveNativeTarget` 每次 call 都重新 enumerate；`testResolverIsStatelessAcrossPureCalls` 驗證 `ResolvedWindowTarget` 是 value type 無 reference leak（對應 design `### Decision: Stateless resolver — no cache`）
- [x] 1.6 跑 `swift test --filter WindowIndexResolverTests` 確認全數 GREEN（18/18 pass）

## 2. Tab auto-switch helper

- [x] 2.1 `WindowIndexResolverTests.swift` 的 `testPickUrlContainsSingleMatchBackgroundTab` / `testPickDocumentIndexMapsToOwningWindow` 驗證 resolver 對 background tab URL 正確回傳 `tabIndexInWindow`；已在 1.3 合併實作（對應「Tab auto-switch before keystroke dispatch」requirement 和 design `### Decision: Tab auto-switch before keystroke for native path`）
- [x] 2.2 新增 `SafariBridge.ResolvedWindowTarget { windowIndex: Int; tabIndexInWindow: Int? }` struct，`resolveNativeTarget` / `pickNativeTarget` 都回傳這個型別，同時攜帶 window index 和 tab-in-window index
- [x] 2.3 在 `SafariBridge.swift` 新增 `performTabSwitchIfNeeded(window: Int, tab: Int?) async throws` — tab 為 nil 立即 return，否則送 `set current tab of window N to tab T of window N` AppleScript
- [x] 2.4 `WindowIndexResolverTests.testPerformTabSwitchIfNeededWithNilTabIsNoOp` 驗證 nil tab 是 no-op（用 garbage window index 99 驗證沒呼叫 AppleScript — 若 AppleScript 執行就會 error）；背景 tab 實際 switch 的 end-to-end 驗證歸 task 10.1 integration test

## 3. 改造 UploadCommand（第一個 migration 目標）

- [x] 3.1 新增 `CommandParsingTests` 測試：`testUploadCommand_nativeModeAcceptsUrlTarget`、`testUploadCommand_nativeModeAcceptsTabTarget`、`testUploadCommand_nativeModeAcceptsDocumentTarget`、`testUploadCommand_allowHidAcceptsUrlTarget`、`testUploadCommand_nativeRejectsMutuallyExclusiveTargets`；刪除對應的 4 個 #23 R5 reject 測試（對應「Upload command accepts full TargetOptions on all execution paths」requirement）
- [x] 3.2 `UploadCommand.swift` 的 `validate()` 移除 `if native || allowHid { reject url/tab/document }` 區塊，抽出 `checkJsSizeCap()` 供 run() 在 JS fallback 時 reuse
- [x] 3.3 `UploadCommand.swift` 新增 `runNativeWithResolver(expandedPath:)` 呼叫 `SafariBridge.resolveNativeTarget` + `performTabSwitchIfNeeded`，再呼叫既有 `uploadViaNativeDialog(..., window: resolved.windowIndex)`；當 tab switch 發生時 emit 額外 stderr 提示（Tab auto-switch classified as transitively authorized interference requirement）；`run()` 重組路由：explicit --js → JS；explicit --native/--allow-hid OR AX granted → `runNativeWithResolver`；no AX → JS fallback with size cap 檢查 + 警告
- [x] 3.4 更新既有 `testUploadCommand_smartDefaultWithUrlTargetRejectsOver10MB` → `testUploadCommand_smartDefaultWithUrlTargetAllowsLargeFileAtValidate`：`--url plaud` 搭配 11 MB 檔案 + 無 `--native` 時，validate **不**再 fail（#26 smart default 路由改經 native）；新增 `testUploadCommand_explicitJsWithUrlRejectsOver10MB` 覆蓋 explicit --js + targeting 仍受 cap 限制（對應「Upload command preserves 10 MB JS hard cap under targeting flags」requirement）
- [x] 3.5 跑 `swift test --filter UploadCommand`，21/21 tests pass，全部既有 upload tests 無 regression

## 4. 改造 CloseCommand / PdfCommand

- [x] 4.1 `CommandParsingTests` 新增 `testCloseCommand_acceptsUrlFlag` / `testCloseCommand_acceptsDocumentFlag` / `testCloseCommand_acceptsTabFlag` / `testCloseCommand_rejectsMutuallyExclusiveTargets`，更新既有 `testCloseCommand_defaultsNoTarget` / `testCloseCommand_acceptsWindowFlag` 改用 `target.resolve()` — 對應「WindowOnlyTargetOptions removal」requirement 的 close scenarios
- [x] 4.2 `CommandParsingTests` 新增 `testPdfCommand_acceptsUrlFlag` / `testPdfCommand_acceptsDocumentFlag` / `testPdfCommand_acceptsTabFlag` / `testPdfCommand_rejectsMutuallyExclusiveTargets`，更新既有 `testPdfCommand_defaultsNoTarget` / `testPdfCommand_acceptsWindowFlag` 改用 `target.resolve()` — 對應「PDF export command accepts full TargetOptions」requirement
- [x] 4.3 `CloseCommand.swift` 改 `@OptionGroup var target: TargetOptions`，`run()` 先 `resolveNativeTarget` → `performTabSwitchIfNeeded` → `closeCurrentTab(window: resolved.windowIndex)`
- [x] 4.4 `PdfCommand.swift` 同樣 migration —`TargetOptions`，`run()` 先 `resolveNativeTarget` → emit tab-switch stderr 提示（若需）→ `performTabSwitchIfNeeded` → 原 keystroke dispatch（raisePrelude 改用 `resolved.windowIndex` uniformly）
- [x] 4.5 `swift test` 全部 151/151 GREEN，包含 close / pdf 新舊測試

## 5. 改造 ScreenshotCommand（AX no-raise 邏輯）

- [x] 5.1 `CommandParsingTests` 新增 `testScreenshotCommand_acceptsUrlFlag` / `testScreenshotCommand_acceptsDocumentFlag` / `testScreenshotCommand_acceptsTabFlag` / `testScreenshotCommand_acceptsFullWithUrl` / `testScreenshotCommand_rejectsMutuallyExclusiveTargets`（對應「Screenshot command accepts full TargetOptions」requirement）
- [x] 5.2 `ScreenshotCommand.swift` 改 `@OptionGroup var target: TargetOptions`
- [x] 5.3 `run()` 依 `hasExplicitTarget` 判斷：有目標 flag → `resolveNativeTarget` 取 windowIndex；無 flag → 保留 legacy `nil` 傳 `resolveWindowForCapture` 觸發 CG fallback path；`tabIndexInWindow` 刻意**忽略**不 switch tab（對應 design `### Decision: Screenshot AX path does NOT raise target window` 和「Hidden window capture via Accessibility bounds does not raise」requirement）；`docTarget` 使用 `target.resolve()` 讓 `--full --url plaud` 從 plaud document 直接讀 dimensions
- [x] 5.4 既有 `resolveWindowForCapture(window: nil)` 的 CG name-match legacy fallback 保留 — 沒傳 flag 時自動走這條，AX 不可用時不炸；AX 可用時走 AX bounds path 讀 hidden window 不 raise
- [x] 5.5 新增 source-level guard test `testScreenshotCommand_sourceDoesNotTabSwitch`：grep `ScreenshotCommand.swift` 確認無 `performTabSwitchIfNeeded` 呼叫，防止未來 refactor 意外破壞非干擾契約（對應「Screenshot Accessibility path remains non-interfering for background windows」requirement）

## 6. 刪除 WindowOnlyTargetOptions

- [x] 6.1 確認 `Sources/SafariBrowser` 內無任何檔案仍使用 `WindowOnlyTargetOptions`（grep 只剩 comment references 在 CloseCommand.swift / SafariBridge.swift 為歷史註解，安全）；刪除 `CommandParsingTests.swift` 中 5 個 `WindowOnlyTargetOptions`-specific tests
- [x] 6.2 刪除 `Sources/SafariBrowser/Commands/WindowOnlyTargetOptions.swift`（對應 spec requirement「WindowOnlyTargetOptions removal」和 design decision: Unify window-scoped commands under `TargetOptions`，delete `WindowOnlyTargetOptions`）
- [x] 6.3 `swift test` 全部 152 tests pass（121 原始 + 18 resolver + 2 ambiguousWindowMatch + 11 upload/close/pdf/screenshot 新 targeting tests − 5 WindowOnlyTargetOptions-specific tests）
- [x] 6.4 `swift build -c release` 通過 5.14s 完成

## 7. Backward compatibility 驗證

- [x] 7.1 `CommandParsingTests.testNoTargetFlagResolvesToFrontWindowForAllWindowCommands` 驗證 4 個 window-capable commands（upload --native / close / pdf / screenshot）無 flag 時都 resolve 到 `.frontWindow`，對應 document-targeting spec MODIFIED「Backward compatibility with existing scripts」→「Keystroke operations preserve front-window semantics when no flag given」scenario（runtime raise 行為歸 task 10.1 integration test）
- [x] 7.2 `CommandParsingTests.testNativePathCommandsRouteThroughResolver` source-level guard 確認 upload / close / pdf 都呼叫 `resolveNativeTarget`，避免未來 refactor 意外退回 `target.window` 直取導致 `--url` 被 silent drop（對應「Keystroke operations resolve target when flag given」scenario 的前置條件）

## 8. 多視窗 interference 警告

- [x] 8.1 `UploadCommand.runNativeWithResolver` / `PdfCommand.run` 都在 `resolved.tabIndexInWindow != nil` 時 emit 額外 stderr 行「Target tab will be brought to the front of its window before ...」，在原有 keystroke 警告前出現（對應「Tab auto-switch classified as transitively authorized interference」requirement）
- [x] 8.2 `CommandParsingTests.testTabSwitchWarningEmittedForUploadAndPdf` source-level guard 確認 UploadCommand.swift 和 PdfCommand.swift 原始碼都含「Target tab will be brought to the front」字串，捕捉未來誤刪警告的 regression

## 9. 文件更新

- [x] 9.1 更新 `CLAUDE.md` multi-window section：移除「Window-only primitives 只接受 `--window`」的 rule、新增 #26 native-path resolver 相關 rule（multi-match fail-closed、screenshot 不 tab-switch、upload 路由更新）；新抽象列表加入 `resolveNativeTarget` / `pickNativeTarget` / `listAllWindows` / `performTabSwitchIfNeeded` / `ResolvedWindowTarget` / `ambiguousWindowMatch`；spec 參考加入 `openspec/changes/native-url-resolution/` 和 `non-interference/spec.md`；documents 子命令的 MRU 語義 vs resolver 的 spatial 語義差異已明確文件化（對應 design decision: Modify existing `document-targeting` spec, not a new spec file 的 risks 欄位「Resolver 和 documents 子命令的語義分歧」的文件化）
- [x] 9.2 `CHANGELOG.md` Unreleased 區新增 #26 Breaking Changes 條目（WindowOnlyTargetOptions 移除 + `upload --native` 不再 reject targeting flags）和 Features 條目（完整的 native-path resolver 說明 + 30+ 新 tests + downstream 影響）
- [x] 9.3 更新 `README.md` 的 Multi-document targeting 節：window-only 子集拆到新段落說明接受完整 TargetOptions、ambiguousWindowMatch、tab-switch 副作用、screenshot 不 tab-switch 契約；新範例 `upload --native --url plaud`、`close --url plaud`、`screenshot --url plaud` 等。Plugin `SKILL.md`（psychquant-claude-plugins repo）的更新歸下個 plugin release cycle，非本 change 必需項

## 10. Downstream 驗證（che-local-plugins plaud-transcriber）

- [ ] 10.1 release binary 安裝後，手動測試 `safari-browser upload --native --url plaud "input[type=file]" /path/to/test.mp3` 在多視窗 Safari 環境下能正確打到 Plaud window 並完成上傳
- [ ] 10.2 更新 `che-local-plugins/plugins/plaud-transcriber/skills/plaud-upload/SKILL.md` 到 v1.9.0：移除「請手動切換到 Plaud tab」手工步驟；`safari-browser upload --native ... --url plaud` 取代 Step 2 的無 targeting 版本；bump plugin.json 和 marketplace.json 版本
- [ ] 10.3 以 plaud-upload skill 實際跑一次端到端上傳流程，確認 AI agent autonomy 恢復（使用者可同時在別的 app 工作，不需手動切 Safari tab）

## 11. idd-verify 前置準備

- [ ] 11.1 確認所有 tasks（1–10）均為 `- [x]` completed 狀態
- [ ] 11.2 `git log --oneline` 顯示每個 commit 都引用 `#26`
- [ ] 11.3 準備 `/idd-verify #26` 的 diff 範圍：`git diff main...HEAD --stat`
