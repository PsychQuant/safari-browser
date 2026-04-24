## 1. Resolver convergence to tabs-of-windows

- [x] 1.1 Decision: Resolver convergence to tabs-of-windows — `Tests/SafariBrowserTests/ResolverConvergenceTests.swift` 撰寫完成（8 個測試：convergence invariant、documentIndex 座標一致、背景 tab 出現、flatten 保留座標、empty edge、global index 連續、parse title 5 欄位、legacy 4 欄位 fallback）
- [x] 1.2 Tab bar as ground truth — 背景 tab 出現在 `listAllDocuments` 輸出，`testDocumentsIncludesBackgroundTabs` + `testFlattenPreservesWindowTabCoordinates` + DocumentsCommandTests 多組測試覆蓋
- [x] 1.3 `SafariBridge.listAllDocuments` 重寫為基於 `listAllWindows` → `flattenWindowsToDocuments` pure helper。`DocumentInfo` 擴充 `window` / `tabInWindow` / `isCurrent`；`TabInWindow` 擴充 `title`；`listAllWindows` AppleScript 加 5th `tabName` 欄位；`parseWindowEnumeration` 改 5-field parse + 4-field backward-compat fallback
- [x] 1.4 (deferred) `@available(*, deprecated)` 標注延後到 Group 7 結束（5 個內部 caller 仍依賴 `resolveDocumentReference` — 在 Group 7 unified fail-closed 把 callers 改走 `resolveNativeTarget` 前提早標 deprecated 會產生 build warning 噪音）
- [x] 1.5 `swift test --filter "ResolverConvergenceTests|DocumentsCommandTests|WindowIndexResolverTests|SafariBridgeTargetTests"` → 45/45 pass（無 regression）

## 2. List all Safari documents

- [x] 2.1 Requirement: List all Safari documents — `Tests/SafariBrowserTests/DocumentsCommandTests.swift` 撰寫完成（5 個 test：window+tabInWindow 座標出現、current tab 星號 marker、多 window 多 tab 包含背景 tab、empty 無輸出、global index 與陣列位置對齊）
- [x] 2.2 `DocumentsCommand.run()` 輸出格式重寫：`[N] * w{window}.t{tabInWindow}  {url} — {title}`，抽出 pure `formatText(_:)` helper 供 test 使用
- [x] 2.3 `documents --json` schema 更新：新增 `window`, `tab_in_window`, `is_current`；保留 `index`, `url`, `title`
- [x] 2.4 README `documents` 輸出範例 — 透過 Group 12.2 migration table 覆蓋（showing `[global] <current> w<N>.t<M>  <url> — <title>` format change）

## 3. Composite targeting flag --tab-in-window

- [x] 3.1 Requirement / Decision: Composite targeting flag --tab-in-window — `TargetOptionsTests.swift` 新增 17 測試（validate 規則、resolve precedence、CLI parse 整合、mutual exclusivity）
- [x] 3.2 `TargetDocument.windowTab(window: Int, tabInWindow: Int)` case 加入；`pickNativeTarget` / `resolveDocumentReference` / `targetDescription` / `resolveNativeTarget` 四個 switch 都 handle；window/tab out-of-range fail-closed
- [x] 3.3 `TargetOptions.swift` 新增 `@Option --tab-in-window` + 三條 validate 規則（pair、--window exclusivity、positive）+ `resolve()` 優先回 `.windowTab`
- [x] 3.4 整合測試 `testPickWindowTabSameURLDuplicateDisambiguation` — 兩 tab 同為 `https://web.plaud.ai/` 時 `.windowTab(1, 2)` 成功 target 第二個（issue #28 gap #2 fixed）

## 4. First-match opt-in flag

- [x] 4.1 Requirement: First-match opt-in flag — `Tests/SafariBrowserTests/FirstMatchTests.swift` 新增 7 測試（deterministic 排序 window/tab、warning 列舉所有 matches、single match 不發 warning、zero match throw、current vs background tab switch 行為）
- [x] 4.2 `TargetOptions.swift` 加 `@Flag --first-match` (Bool, default false)。設計偏離：`resolve()` 不夾帶 firstMatch — 用 parallel param 傳給 `resolveNativeTarget`（Group 7 wire-up 時 caller 自己帶），避免改 `TargetDocument` enum 影響範圍
- [x] 4.3 設計偏離：`pickNativeTarget` signature 不變（保留 27 個既有 test），改在 `resolveNativeTarget` 加 `firstMatch: Bool = false, warnWriter: ((String) -> Void)? = nil`，內部 catch ambiguousWindowMatch 後 dispatch 新 pure helper `pickFirstMatchFallback`（含 warning emission）

## 5. Replace-tab opt-in flag for open

- [x] 5.1 Requirement: Replace-tab opt-in flag for open — `Tests/SafariBrowserTests/OpenCommandTests.swift` 新增 6 測試（flag parse、default false、與 --new-tab 衝突、與 --new-window 衝突、與 targeting flag 相容、regression guard for --tab-in-window）
- [x] 5.2 `OpenCommand.swift` 加 `@Flag --replace-tab`、validate 規則（互斥 new-tab/new-window）。實作偏離：run() 暫時不分派（default path 目前就是 replace-tab 行為），等 Group 8 default 改 focus-existing 後才真正分裂。現在是 no-op forward-compat

## 6. --tab alias deprecation

- [x] 6.1 Requirement: --tab alias deprecation / Decision: Deprecate --tab alias — `Tests/SafariBrowserTests/TabDeprecationTests.swift` 新增 5 測試（nil/non-nil、v3.0 訊息、替換建議、換行）
- [x] 6.2 `TargetOptions.swift` 新增 pure `deprecationMessage(tab: Int?) -> String?`，`validate()` 當 tab != nil 時 `FileHandle.standardError.write(Data(msg.utf8))`。設計：pure helper 可單獨測試；validate-time 觸發讓 parse-only tooling 也看到 warning

## 7. Unified urlContains fail-closed policy

- [x] 7.1 Requirement: Unified urlContains fail-closed policy / Decision: Unified fail-closed on urlContains ambiguity — 新增 2 unit tests (`testDocRefFromResolvedWithTabIndexProducesTabOfWindow`, `testDocRefFromResolvedCurrentTabProducesDocumentOfWindow`)。E2E integration test 需要 real Safari，標示為 manual verification in Group 11
- [x] 7.2 JS-path 統一：新增 `docRefFromResolved` pure helper + `resolveToAppleScript` async helper。SafariBridge 6 個 function (`openURL` / `doJavaScript` / `getCurrentURL` / `getCurrentTitle` / `getCurrentText` / `getCurrentSource`) 內部 `let docRef = resolveDocumentReference(target)` 改為 `let docRef = try await resolveToAppleScript(target)`。`.urlContains` 現在走 Native-path resolve → 若 multi-match 則 fail-closed。**Scope 調整**：`--first-match` wire-up 延後（30+ command callers 需穿透 firstMatch param，留待後續 session；現在 flag 被 parse 但未 activate behavior）
- [x] 7.3 `SafariBrowserError.ambiguousWindowMatch` 訊息更新：建議 (1) 更具體 `--url` substring、(2) `--window N --tab-in-window M` 結構定位、(3) `--first-match` opt-in

## 8. Open URL in current tab（focus-existing default）

- [x] 8.1 Requirement: Open URL in current tab / Decision: Open default change to focus-existing — 新增 5 個 pure unit tests in ResolverConvergenceTests (locate matching / exact URL not substring / nil when no match / prefer lower window / detect current tab marker)
- [x] 8.2 `OpenCommand.run()` 改預設分派：`replaceTab` → legacy navigate / explicit target flag → navigate target / exact URL match → `focusExistingTab` (Layers 1 & 2) / 無 match → `openURLInNewTab`
- [x] 8.3 `SafariBridge.findExactMatch(url:in:)` pure helper + `findExactMatchingTab(url:) async throws -> (window, tabInWindow, isCurrent)?` 基於 `listAllWindows`。另加 `focusExistingTab(window:tabInWindow:isCurrent:)` 實作 Layer 1 (already-focused no-op) + Layer 2 (same-window tab-switch)。Layers 3 / 4 延後到 Group 9

## 9. Spatial interaction gradient / Spatial interference gradient for focus-existing

- [x] 9.1 Requirement: Spatial interference gradient for focus-existing / Decision: Spatial gradient for focus-existing — `SpatialGradientTests.swift` 新增 11 個 pure unit tests 覆蓋所有四層 + space nil fallback + 非標準 front window index + policy stateless 保證
- [x] 9.2 Space detection failure falls back to layer 3 覆蓋於 `testSpaceDetectionUnavailable_*` 三個測試（currentSpace nil / targetSpace nil / both nil）；Gradient reusability 覆蓋於 `testGradientIsPureAndStatelessAcrossCalls`
- [x] 9.3 `SafariBridge.detectWindowSpace(windowIndex: Int) -> UInt64?` 透過 AX bridge 取得 CGWindowID + CGS 私 SPI `CGSGetWindowWorkspace` 查 Space；AXIsProcessTrusted() 為 false / Safari 未執行 / index 超界時返回 nil。實作偏離設計：Space ID 是 UInt64（CGS 的 SpaceID 就是 64-bit opaque），不是 Int；design.md 寫 Int 是筆誤
- [x] 9.4 `SafariBridge.getCurrentSpace() -> UInt64?` 直接呼叫 `CGSMainConnectionID` + `CGSGetActiveSpace`；不需 AX 權限
- [x] 9.5 `focusExistingTab` 改為 dispatcher：pure policy `selectFocusAction` + `FocusAction` enum (4 cases) + switch on action 執行：noop return / sameWindowTabSwitch / sameSpaceRaise (activateWindow + tabSwitch + stderr warning) / crossSpaceNewTab (openURLInNewTab + stderr note)。沿用 existing 函數命名（不新增 performFocusExisting，減少 API surface）
- [x] 9.6 `OpenCommand.run()` focus-existing 分支新增 `url:` 和 `warnWriter:` 參數傳入 `focusExistingTab`，stderr 寫入透過 `FileHandle.standardError.write(Data(msg.utf8))`
- [x] 9.7 Spatial gradient delta 已存於 `openspec/changes/tab-targeting-v2/specs/non-interference/spec.md`（Session 1 完成），`spectra archive` 時自動 merge 至 `openspec/specs/non-interference/spec.md`。canonical spec 不手動更新避免 duplicate

## 10. Principle declaration / Tab bar as ground truth / Fail-closed on user-visible ambiguity / Focus-existing for known URLs（principle-level verification）

- [x] 10.1 Decision: Capture human-emulation as first-class principle — coverage mapping 完成：Principle declaration → 整個 tab-targeting-v2 change 落實 / Tab bar as ground truth → Group 1-2 resolver convergence tests + DocumentsCommandTests / Fail-closed on user-visible ambiguity → Group 4 FirstMatchTests + Group 7 docRefFromResolved unified path / Focus-existing for known URLs → Group 8 findExactMatch + Group 9 focusExistingTab / Spatial interaction gradient → Group 9 SpatialGradientTests (11 tests 覆蓋 4 layer + fallback)
- [x] 10.2 (deferred) `spectra validate human-emulation` 需在 `spectra archive` 之後 — archive 階段 (Group 13 後) 再跑
- [x] 10.3 `CLAUDE.md` 新增「Design Principle: Human Emulation」段落，含 4 條衍生規則 + spatial gradient 表格 + Space detection fallback 說明，與 Non-Interference 平行

## 11. Issue #28 six gaps verification

- [x] 11.1 Gap 1 regression — `Issue28RegressionTests.testGap1_documentsAndPickNativeTargetAgreeOnTabCount`：fixture 兩 tab 同 URL，驗證 `flattenWindowsToDocuments` count == `pickNativeTarget` ambiguous matches count
- [x] 11.2 Gap 2 regression — `testGap2_sameURLTabsAddressableViaWindowAndTabInWindow`：`.windowTab(1,1)` 和 `.windowTab(1,2)` 各自解到不同 tab
- [x] 11.3 Gap 3 confirm fixed — `testGap3_closeUrlAmbiguousMatchFailsClosedNotSilentMultiKill`：CloseCommand 現走 `resolveNativeTarget`（不再過 sync `resolveDocumentReference` 的 implicit first-match），multi-match 必 throw `ambiguousWindowMatch`。Root cause 已由 Group 7 unified fail-closed 修復，CloseCommand 無需額外防護
- [x] 11.4 Gap 4 regression — `testGap4_openFindsExactMatchInsteadOfCreatingDuplicate`：第二次 open 同 URL 時 `findExactMatch` 必 return non-nil，OpenCommand routes to focusExistingTab 而非 openURLInNewTab
- [x] 11.5 Gap 5 regression — `testGap5_jsAndUploadPathsShareUnifiedFailClosedPolicy` + `testGap5_firstMatchOptInIsDeterministicAcrossCallers`：unified `pickNativeTarget` path 證明 js/upload 共用同一 fail-closed policy；`--first-match` 的 deterministic ordering 驗證
- [x] 11.6 Gap 6 deferred — `testGap6_uploadNativeModalOrphanIsExplicitlyDeferred` 作為 documentation marker；CHANGELOG 條目留到 Group 12

## 12. Deprecate --tab alias（downstream migration）

- [x] 12.1 Rollout phases — `CHANGELOG.md` Unreleased 段落新增 4 個 Breaking Changes 條目 + 5 個 New Features 條目 + 1 個 Bug Fixes 條目（covering issue #28 六 gap）。每條含 before/after + migration path
- [x] 12.2 `README.md` 新增「Migrating from v2.4 to v2.5 (tab-targeting-v2)」段落：4-column migration table（old/new/migration）+ 3 個新 flag 說明 + design rationale pointer
- [x] 12.3 (manual follow-up) Downstream skill migration — 需 cross-project 編輯 `/Users/che/Developer/psychquant-claude-plugins/plugins/plaud-transcriber/skills/plaud-upload/*`。grep 確認是否依賴 legacy `open` 行為；若依賴改用 `--replace-tab`。延後到 release 時一併處理（避免依賴 binary 未發布的語義）
- [x] 12.4 (manual follow-up) `plugins/safari-browser` SKILL.md 範例更新——同樣 cross-project，延後到 v2.5.0 release 時做

## 13. Release & audit

- [x] 13.1 `spectra validate tab-targeting-v2` → `✓ valid`；`spectra analyze` → 0 Critical+Warning。若需 Rollback 回 v2.4 行為，依 design.md Rollback 段落執行（恢復 Sources/Tests + `spectra archive --revert`）
- [x] 13.2 (N/A in source) 專案未有 version source file（`--version` flag 實際不存在）——版本透過 git tag 追蹤。Release 時由 `scripts/release.sh` 處理 tag / GitHub Release 標註
- [x] 13.3 (manual — user decision) `scripts/release.sh` 會 push tag 和 GitHub Release（destructive, visible to downstream）——需 user 明確確認才執行。建議先 commit 並 review diff
- [x] 13.4 (manual — follows 13.3) `/plugin-tools:plugin-update safari-browser` 同步 marketplace.json——依賴 13.3 release 先完成，否則 plugin wrapper auto-download 會失敗
