<!--
這個變更是 #353 第一輪驗證之後的修正（fix round 1）。規則同第一個變更：
- 每個 Example 有一個帶 `spec-example: <capability> / <Example title>` 標記的測試，逐列斷言。
- 沒有任何測試可以執行 /usr/bin/osascript、System Events、screencapture、Accessibility 或真的 Safari。
- 每個 commit 的 subject 以 (#353) 結尾。
程式與測試已在 fix round 1 的 commit 完成；下列任務記錄每個 Example 由哪個測試驗證。
-->

## 1. 共用：錯誤的階段、以編號辨認、profile 下的 miss、假 Safari

- [x] 1.1 假 Safari 依 AppleScript 的規則比較文字：`considering case … end considering` 之內分大小寫，之外不分；並能判斷 `if (count of tabs of <window>) < T`。驗證：`WindowLevelTargetTests.testTheFakeIgnoresCaseOutsideConsideringCase`；把 `urlGuardClause` 或 `exactURLGuardClause` 的 `considering case` 拿掉時，`testTheURLCheckBeforeActing`／`testTheFakeIgnoresCaseOutsideConsideringCase` 失敗。
- [x] 1.2 測試：Example「what a target-changed error says」（document-targeting，requirement「Window-level commands act on the window they resolved」）。`SafariBrowserError.targetChangedBeforeActing(expected:stage:)` 的三個階段各有自己的文字，都帶目標、都不說重新解析。標記 `spec-example: document-targeting / what a target-changed error says`。驗證：`WindowLevelTargetTests.testTheTargetChangedErrorSaysWhatHadAlreadyHappened`。
- [x] 1.3 測試：Example「markers by number」（同一條 requirement）。`translatingWindowLevelMarkers` 以錯誤結尾的編號辨認 9001／9002／9003；文字裡出現同名字串而編號是 -1728 的錯誤原樣通過；-1728 只有在呼叫端標示為 Safari 讀取時才算 miss。標記 `spec-example: document-targeting / markers by number`。驗證：`WindowLevelTargetTests.testAMarkerIsReadFromTheErrorNumberNotFromTheText`。
- [x] 1.4 測試：Example「misses of window-level commands under a profile」（document-targeting，requirement「Document not found surfaces discoverable error」）。`notFoundError(for:profile:)` 對表中七列給出樣式與清單；另一個 profile 的分頁不出現。標記 `spec-example: document-targeting / misses of window-level commands under a profile`。驗證：`WindowLevelTargetTests.testMissesOfWindowLevelCommandsUnderAProfile`。
- [x] 1.5 測試：Example「cases that keep the position」新增的三列（使用者輸入的視窗 id、以網址找到而紀錄沒有 id 的分頁、`screenshot` 不算目標的旗標）。驗證：`WindowLevelTargetTests.testCasesThatKeepThePosition`。
- [x] 1.6 測試：Example「the URL check before acting」的失敗列改為斷言呼叫端讀到的 target-changed 錯誤（不再只看腳本的原始標記）；網址需要跳脫、以及在第 2,000 個字元切斷的情形另有測試。驗證：`WindowLevelTargetTests.testTheURLCheckBeforeActing`、`testTheURLCheckCarriesAURLThatNeedsEscaping`、`testEveryWindowLevelScriptCompiles`。
- [x] 1.7 實作 1.2–1.6：`SafariBrowserError.TargetChangeStage` 與三段文字；`SafariBridge.WindowLevelMarker`、`translatingWindowLevelMarkers(target:profile:translateNotFound:stage:_:)` 以編號轉換，並在 profile 之下把 id 目標的 miss 重新表述；`windowIDMiss`、`windowIDCandidateEntries`；`tabGoneCheck`；`actingWindow` 對輸入的視窗 id 一律回傳 `.id`。

## 2. upload 的 native 路徑

- [x] 2.1 測試：Example「native upload by window id」（file-upload，requirement「Upload command accepts full TargetOptions on all execution paths」）更新與新增的各列（讀到的網址不符旗標、讀與點之間換了目前分頁、對話框腳本第一個 Safari 區塊的四種失敗、視窗 id 讀不到）。測試執行 `UploadCommand.runNativeUpload`，只替換 System Events 探測、對話框腳本的執行與 stderr。標記 `spec-example: file-upload / native upload by window id`。驗證：`WindowLevelNativeDialogTests.testNativeUploadByWindowID`。
- [x] 2.2 測試：Example「front window check before every keystroke」（同一條 requirement「Upload command accepts full TargetOptions on all execution paths」）。擁有者檢查的四個條件與順序、網址比對在 `considering case` 之內、七次呼叫的位置（兩個等待各一次、等檔案對話框的那個等待沒有）。標記 `spec-example: file-upload / front window check before every keystroke`。驗證：`WindowLevelNativeDialogTests.testFrontWindowCheckBeforeEveryKeystroke`。
- [x] 2.3 測試：Example「tab switch scripts」（document-targeting，requirement「Tab auto-switch before keystroke dispatch」）新增的兩列（分頁腳本之後換了網址；`pdf` 指到的分頁已不在）。標記 `spec-example: document-targeting / tab switch scripts`。驗證：`WindowLevelNativeDialogTests.testTabSwitchScripts`。
- [x] 2.4 對話框腳本回報的狀況由 `runNativeUpload` 依階段轉換；System Events 與擁有者檢查自己的錯誤原樣通過。驗證：`WindowLevelNativeDialogTests.testWhatTheDialogScriptReportsIsTranslatedForTheStageItRanAt`。
- [x] 2.5 profile 之下，解析之後才關掉的視窗在讀與點的步驟回報該 profile 的分頁。驗證：`WindowLevelCommandsTests.testAPinnedWindowUnderAProfileThatClosesAfterTheResolutionListsTheProfilesTabs`。
- [x] 2.6 實作 2.1–2.5：`UploadCommand.nativeUploadPlan` 比對讀到的網址、把分頁與網址檢查交給對話框腳本；`nativeDialogScript(path:window:tab:guardClause:)` 的第一個 Safari 區塊與 `verifyUploadOwner(expectedID, expectedURL)`；`runNativeUpload(_:ensureLive:runDialogScript:warn:)`。

## 3. pdf

- [x] 3.1 測試：Example「export script by window id」（pdf-export，requirement「PDF export command accepts full TargetOptions」）更新的一列與新增的一列（`--window-id --tab-in-window` 的完整順序；指到的分頁已不在時以 9003 結束、miss 是 `window id 5822 tab 2`）。標記 `spec-example: pdf-export / export script by window id`。驗證：`WindowLevelNativeDialogTests.testExportScriptByWindowID`。
- [x] 3.2 測試：Example「save-dialog advice after a failed export」（requirement「PDF export command accepts full TargetOptions」）。標記 `spec-example: pdf-export / save-dialog advice after a failed export`。驗證：`WindowLevelNativeDialogTests.testTheSaveDialogAdviceFollowsOnlyAnErrorThatCanLeaveOneOpen`；提示只寫在這個判斷之內由 `testTheSaveDialogAdviceIsWrittenOnlyInsideItsCheck` 檢查原始碼的形狀（`run()` 需要 GUI 與鍵盤，無法在測試執行）。
- [x] 3.3 實作：`bringTabForwardStatements` 以 `tabGoneCheck` 開頭；`PdfCommand.needsRecoveryAdvice(after:)`。

## 4. screenshot

- [x] 4.1 測試：Example「page steps by window id」（screenshot，requirement「Screenshot command accepts full TargetOptions」）。測試執行 `ScreenshotCommand.captureWindow(session:resolve:)`、`pageTarget(capture:options:)` 與 `pageStep`。標記 `spec-example: screenshot / page steps by window id`。驗證：`WindowLevelCaptureAndFocusTests.testPageStepsByWindowID`。
- [x] 4.2 交給擷取解析器的是解析出來的視窗；`screenshot` 不切分頁、不拉視窗。驗證：`WindowLevelCaptureAndFocusTests.testTheCaptureResolverIsHandedTheResolvedWindow`、`testScreenshotChangesNothingInSafari`、`testRunStartsFromTheResolvedCapture`（原始碼形狀）、`CommandParsingTests.testScreenshotCommand_sourceDoesNotTabSwitch`（改為檢查現存的函式名稱）。
- [x] 4.3 實作：`SafariBridge.pageTarget(for:named:profile:)`、`ScreenshotCommand.CaptureTarget.pageTarget`、`captureWindow(session:resolve:)`、`pageTarget(capture:options:)`、`pageStep(_:capture:_:)`。封存之後的 commit `ac5fc67`：沒有解析出目標時（`screenshot` 不算目標的四個旗標）頁面步驟在最前面的視窗上執行；視窗或分頁不在時 `pageStep` 回報 document-not-found，只有分頁還在而不再是目前分頁時才是 `anchoredTargetChanged`。`81f0850`：`--profile` 之下，頁面步驟對視窗目標的 miss 帶著 profile 重新表述（列出該 profile 的分頁），與指令的其他步驟一致。

## 5. open：顯示既有分頁

- [x] 5.1 測試：Example「focus-existing by window id」（human-emulation，requirement「Spatial interaction gradient」）新增的一列（網址檢查失敗時沒有警告），並改為執行 `OpenCommand.revealExisting(url:warn:spaces:)`。標記 `spec-example: human-emulation / focus-existing by window id`。驗證：`WindowLevelCaptureAndFocusTests.testFocusExistingByWindowID`。
- [x] 5.2 以位置顯示時是同一段腳本、同樣的檢查；分頁不在時是 miss；沒有符合的分頁時不送任何後續腳本。驗證：`WindowLevelCaptureAndFocusTests.testAMatchWithoutAWindowIDFallsBackToThePosition`、`testATabThatClosedBeforeItWasRevealedIsAMiss`、`testNoExistingTabIsNotARevealAndSendsNothingMore`。
- [x] 5.3 實作：`focusExistingScript(window:tab:url:raise:)`、`focusExistingTab` 的單一腳本與警告的時機、`OpenCommand.revealExisting`。

## 6. 文件與其他

- [x] 6.1 `close --help` 的摘要改為「Close a tab: the tab a targeting flag names, or the current tab」。
- [x] 6.2 window-enumeration 的 Example「rejected shapes」：帶標記的測試也斷言第 4、5 列的建議文字。驗證：`WindowEnumerationDecoderTests.testRejectedShapes`。
- [x] 6.3 變異檢查：這一輪的 35 個行為各退回一次（封存時 31 個；封存之後的 commit `ac5fc67` 與 `81f0850` 為 `screenshot` 的頁面步驟再加 4 個），每一個都有具名的測試失敗（紀錄在 issue 的 Implementation Complete）。
- [x] 6.4 `README.md`、`CHANGELOG.md`、`CLAUDE.md` 與程式註解對齊現在的行為（驗證報告第 15、17、20 列）。
- [x] 6.5 在 mini 上跑完整的 `swift test`（2638 個測試；第一次有一個失敗：`URLTextTests.testTheNumberOfRedactionSitesIsWhatWasReviewed`，因為這一輪新增了一處脫敏後的清單，已把處數改為 15 並寫明原因）。
