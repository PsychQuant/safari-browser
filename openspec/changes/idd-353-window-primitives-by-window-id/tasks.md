<!--
Each task states the behavior delivered and how it is verified.
規則（適用於每一個任務）：
- TDD：每個 Example 的測試先寫、先看到它失敗，再寫程式。
- 沒有任何新測試可以執行 /usr/bin/osascript、System Events、screencapture 或 Accessibility；測試只到腳本邊界（design「測試只到腳本邊界」）。
- 每個 Example 的測試檔帶一行標記 `spec-example: <capability> / <Example title>`。
- 每個 commit 的 subject 以 (#353) 結尾。
-->

## 1. 共用基礎：視窗的指稱、網址比對、視窗不見的錯誤

涵蓋 design「視窗層級的指令以 ActingWindow 指稱目標視窗」「以網址比對的目標在動手前重新確認」「視窗不見時的錯誤沿用 pinWindowAtStart 的寫法」「測試只到腳本邊界」。

- [x] 1.1 測試用的假 Safari 能反映這次要驗的行為：新增 `WindowLevelFakeSafari`（`Tests/SafariBrowserTests/`），記住每個視窗的目前分頁、套用 `close tab T of window id W`／`close current tab of …`／`set current tab …`／`set index …` 並記錄下來，遇到腳本裡的網址比對（`SB_TARGET_CHANGED`，四種比較）照當下分頁的網址決定報錯與否，視窗不存在時回 -1728。驗證：它自己的測試（比對不符時丟出含 9001 的錯誤且不套用後面的動作；關閉背景分頁後目前分頁不變）
- [x] 1.2 測試先行：Example「cases that keep the position」（requirement「Window-level commands act on the window they resolved」）。`SafariBridge.actingWindow(for:named:profile:)` 對沒有旗標、`--window N` 釘不住、`--profile` 單獨使用、列舉紀錄沒有 id 四種情況回傳表中的指稱；`close`、`close --window 2`（讀不到 id）、`close --window 5`、`close --profile Work` 在假 Safari 上送出的腳本與 note 符合表格。標記 `spec-example: document-targeting / cases that keep the position`。驗證：`WindowLevelTargetTests` 的對應測試先失敗後通過
- [x] 1.3 測試先行：Example「what the resolver returns」（requirement「Native path URL resolution to window index」）。`pickNativeTarget` 對表中五種旗標回傳視窗序號、視窗 id、視窗內的分頁序號與 `matchedURL`（只有網址旗標有值）。標記 `spec-example: document-targeting / what the resolver returns`。驗證：`WindowLevelTargetTests` 的對應測試
- [x] 1.4 測試先行：Example「the URL check before acting」（requirement「Window-level commands act on the window they resolved」）。`SafariBridge.tabGuardClause(named:matchedURL:)` 產生的片段在假 Safari 上對表中八列得到「動手」或 target-changed；`--url-regex` 用解析時讀到的網址（超過 2,000 字元比對前 2,000 字元），位置旗標沒有片段。標記 `spec-example: document-targeting / the URL check before acting`。驗證：`WindowLevelTargetTests` 的對應測試
- [x] 1.5 實作 1.2–1.4 所需的型別與函式（design「視窗層級的指令以 ActingWindow 指稱目標視窗」「以網址比對的目標在動手前重新確認」）：`SafariBridge.ActingWindow`、`actingWindow(for:named:profile:)`、`actedTarget(for:named:profile:)`、`ResolvedWindowTarget.matchedURL`（`pickNativeTarget` 的網址分支與 `pickFirstMatchFallback` 填入）、`tabGuardClause(named:matchedURL:)`、`SafariBrowserError.targetChangedBeforeActing(expected:)` 與它的訊息（說明沒有對那個分頁做任何事）。驗證：1.2–1.4 的測試通過；`WindowIndexResolverTests` 既有測試不變
- [x] 1.6 視窗不見時得到同一種錯誤（design「視窗不見時的錯誤沿用 pinWindowAtStart 的寫法」）：把 `runTargetedAppleScript` 的「找不到物件」轉換抽成可共用的函式；新增把含 `SB_WINDOW_GONE`（9002）的 AppleScript 錯誤轉成該錯誤、把含 `SB_TARGET_CHANGED`（9001）的錯誤轉成 `targetChangedBeforeActing` 的包裝。驗證：單元測試，對 `.windowID(5822, nil, pinnedFrom: 2)` 得到 pattern `window 2 (window id 5822 at command start)`，對未釘住的 `.windowID(5822)` 得到 `window id 5822`；既有 `WindowPin*Tests` 不變

## 2. close

涵蓋 design「close 以一段腳本關閉解析出來的分頁」「四個指令在開頭呼叫 pinWindowAtStart」。

- [x] 2.1 測試先行：Example「which tab close closes」（requirement「Close current tab」）。在假 Safari 上執行 `CloseCommand`，表中六列各自關掉指定的分頁；關背景分頁時該視窗的目前分頁不變；整個指令沒有送出 `set current tab`；關閉是一段腳本；分頁換了網址時 target-changed、沒有東西被關。標記 `spec-example: navigation / which tab close closes`。驗證：`WindowLevelCloseTests` 的對應測試先失敗（現況會切換分頁）後通過
- [x] 2.2 測試先行：Example「close with each targeting flag」（requirement「WindowOnlyTargetOptions removal」）。`close` 接受表中五種旗標並關掉表中的分頁。標記 `spec-example: document-targeting / close with each targeting flag`。驗證：`WindowLevelCloseTests` 的對應測試
- [x] 2.3 測試先行：Example「window-level commands with a window id」（requirement「Target a window by its stable id」）。`close --window-id` 的五列：關對分頁、不存在的 id 與越界的分頁得到 document-not-found 且沒有東西被關、id 不屬於 `--profile` 時失敗。標記 `spec-example: document-targeting / window-level commands with a window id`。驗證：`WindowLevelCloseTests` 的對應測試
- [x] 2.4 實作（design「close 以一段腳本關閉解析出來的分頁」）：`SafariBridge.closeTabScript(windowReference:tab:guardClause:)` 保留「沒有視窗」與「視窗沒有分頁」兩個檢查；`closeResolvedTab(_:named:profile:)` 經 `runTargetedAppleScript` 執行；`CloseCommand.run()` 先 `pinWindowAtStart()`、解析、關閉，不再呼叫切換分頁；移除 `closeCurrentTab(window:profile:)`。`closeCurrentTabScript(windowRef:)` 保留為「沒有指定分頁」的形式（`closeTabScript` 在 `tab` 為 nil 時回傳它，文字不變）。驗證：2.1–2.3 通過；`ZeroTabWindowGuardTests` 的兩個 close 測試不必改且通過；有分頁的形式由 `WindowLevelCloseTests.testTheTabFormKeepsBothChecksInFrontOfTheClose` 檢查兩個檢查都在關閉之前

## 3. pdf

涵蓋 design「pdf 的切換分頁併進匯出腳本」。

- [x] 3.1 測試先行：Example「export script by window id」（requirement「PDF export command accepts full TargetOptions」）。把「釘住、解析、產生匯出腳本」抽成 `PdfCommand` 的方法並在假 Safari 上執行：表中五列的第一個 Safari 區塊符合（存在檢查、網址比對、切分頁、讀網址、拉到前面、`activate` 的順序）；沒有另一段切換分頁的 AppleScript；以 id 進行時腳本不含 `window <數字>`；沒有旗標時腳本與現在逐字相同；`SB_WINDOW_GONE` 轉成 pattern 為 `window 2 (window id 5822 at command start)` 的 document-not-found。標記 `spec-example: pdf-export / export script by window id`。驗證：`WindowLevelNativeDialogTests` 的對應測試
- [x] 3.2 實作（design「pdf 的切換分頁併進匯出腳本」「四個指令在開頭呼叫 pinWindowAtStart」）：`PdfCommand.exportScript(path:window:switchToTab:guardClause:timeout:)`；native 匯出開頭 `pinWindowAtStart()`；`exportNative` 只剩把腳本交給 `runFileDialogScript` 並轉換 `SB_WINDOW_GONE`／`SB_TARGET_CHANGED`；切換分頁的提示維持在鍵盤警告之前。驗證：3.1 通過；`PDFNativeCompletionTests`、`FileDialogScriptSharingTests`、`FileDialogConfirmationPolicyTests` 改用新簽名後原有斷言全數保留並通過

## 4. upload 的 native 路徑

涵蓋 design「upload 在每個按鍵之前檢查最前面的視窗」。

- [x] 4.1 測試先行：Example「native upload by window id」（requirement「Upload command accepts full TargetOptions on all execution paths」）。把「釘住、解析、切換分頁、事前檢查、產生 effects」抽成 `UploadCommand` 回傳計畫的方法並在假 Safari 上執行：表中四列的事前檢查、點擊目標與 dialog 腳本的指稱符合；釘住之後沒有腳本含 `window 2`。標記 `spec-example: file-upload / native upload by window id`。驗證：`WindowLevelNativeDialogTests` 的對應測試
- [x] 4.2 測試先行：Example「front window check before every keystroke」（requirement「Upload command accepts full TargetOptions on all execution paths」）。以 id 進行的 dialog 腳本裡，每一個 `keystroke` 與確認的 `click` 之前（上一個按鍵之後）都有 `verifyUploadOwner` 的呼叫，共七處，第一處在等到檔案對話框之後、第一個按鍵之前；沒有旗標的腳本不含這個呼叫且與現在逐字相同。標記 `spec-example: file-upload / front window check before every keystroke`。驗證：`WindowLevelNativeDialogTests` 的對應測試
- [x] 4.3 測試先行：Example「tab switch scripts」（requirement「Tab auto-switch before keystroke dispatch」）。表中八列：`upload` 對指名的分頁送出一段以 id 的腳本（網址旗標帶比對、位置旗標不帶），背景分頁被設成目前分頁、已是目前分頁的不動；沒有指名分頁時不送；檢查之後分頁被切走則在點擊前停下；`pdf` 的比對與切換在匯出腳本裡、拉到前面之前；`close` 不切換。標記 `spec-example: document-targeting / tab switch scripts`。驗證：`WindowLevelNativeDialogTests` 的對應測試
- [x] 4.4 測試先行：Example「tab switch notice and script」（requirement「Tab auto-switch classified as transitively authorized interference」）。目標是背景分頁時，`upload` 與 `pdf` 在鍵盤警告之前先寫出「目標分頁會被帶到前面」的提示；目標是目前分頁時沒有提示也沒有切換。標記 `spec-example: non-interference / tab switch notice and script`。驗證：`WindowLevelNativeDialogTests` 的對應測試（提示經注入的 writer 收集）
- [x] 4.5 實作（design「upload 在每個按鍵之前檢查最前面的視窗」「四個指令在開頭呼叫 pinWindowAtStart」）：`SafariBridge.bringTabForwardScript(windowReference:tab:guardClause:)`、`bringResolvedTabForward(_:named:profile:)` 與 `clickTarget(for:named:profile:)`；`fileDialogNavigationScript(path:pdfSave:ownerGuard:)`；`UploadCommand.nativeDialogScript(path:window:)` 與 `nativeUploadEffects(selector:path:window:)` 改收 `ActingWindow?`，以 id 進行時定義 `verifyUploadOwner` 並在開頭檢查視窗存在；native 路徑改呼叫 `resolveWindowLevelTarget(named:firstMatch:warnWriter:profile:)`，事前檢查與點擊用 `clickTarget` 的結果。驗證：4.1–4.4 通過；`InterferenceWarningTests`、`FileDialogScriptSharingTests`、`FileDialogConfirmationPolicyTests`、`UploadGuidanceTests` 改用新簽名後原有斷言保留並通過；`pdf` 與沒有 guard 的 `upload` 的導覽片段與現在逐字相同

## 5. screenshot

涵蓋 design「screenshot 以 id 讀 bounds 與標題」。

- [x] 5.1 測試先行：Example「geometry read by window id」（requirement「Screenshot command accepts full TargetOptions」）。把「釘住、解析、拒絕背景分頁」抽成 `ScreenshotCommand` 的方法，把以 id 讀 bounds 與標題抽成可在假 Safari 上執行的一段：表中四列符合（一段腳本、指稱 `window id 5822`、沒有 `set index`／`activate`／`set current tab`；背景分頁在讀取之前被拒絕；視窗關掉時 document-not-found 寫出 `window 2`）。標記 `spec-example: screenshot / geometry read by window id`。驗證：`WindowLevelCaptureTests` 的對應測試
- [x] 5.2 實作（design「screenshot 以 id 讀 bounds 與標題」「四個指令在開頭呼叫 pinWindowAtStart」）：`ScreenshotCommand.run()` 在三項事前檢查之後 `pinWindowAtStart()`，`--full` 的文件目標取自同一份；`SafariBridge.resolveWindowForCapture(window:missTarget:session:resolve:)` 的 `window` 改成 `ActingWindow?`；以 id 進行時「確認存在」與「讀 bounds 與標題」合成一段經 `runTargetedAppleScript` 的腳本；Accessibility 的比對不變。驗證：5.1 通過；`GUISessionTests` 改用新簽名後原有斷言保留並通過

## 6. open 帶出既有分頁

涵蓋 design「open 帶出既有分頁以 id 在一段腳本完成」。

- [x] 6.1 測試先行：Example「focus-existing by window id」（requirement「Spatial interaction gradient」）。以注入的 Space 讀取在假 Safari 上執行 `focusExistingTab`：表中五列各自送出的腳本數與內容符合（第 2 層一段、不含 `set index`／`activate`；第 3 層一段、含比對、切分頁（需要時）、`set index of window id W to 1`、`activate`，並有一行警告；第 4 層不指稱那個視窗）；比對不符時 target-changed、沒有任何變更、沒有開新分頁。標記 `spec-example: human-emulation / focus-existing by window id`。驗證：`WindowLevelFocusTests` 的對應測試
- [x] 6.2 測試先行：Example「gradient actions by window id」（requirement「Spatial interference gradient for focus-existing」）。同一組情境從干擾分級的角度斷言：哪個分頁變成目前分頁、哪個視窗被拉到前面、stderr 有沒有警告，五列符合表格。標記 `spec-example: non-interference / gradient actions by window id`。驗證：`WindowLevelFocusTests` 的對應測試
- [x] 6.3 實作（design「open 帶出既有分頁以 id 在一段腳本完成」）：`findExactMatch(url:in:)` 的回傳 tuple 多帶 `windowID`；`focusExistingTab(window:tabInWindow:isCurrent:url:windowID:warnWriter:spaces:)`，Space 讀取可注入、預設是現在的實作；第 2、3 層有 id 時各送一段經 `runTargetedAppleScript` 的腳本，沒有 id 時維持位置形式；`OpenCommand` 把 `windowID` 傳下去。驗證：6.1、6.2 通過；`ResolverConvergenceTests`、`Issue28RegressionTests`、`SpatialGradientTests`、`OpenCommandTests` 原有斷言保留並通過

## 7. 五條路徑一起檢查

- [x] 7.1 測試先行：Example「references after the resolution」（requirement「Window-level commands act on the window they resolved」）。表中七列各自在假 Safari 上執行到腳本邊界，解析之後送出的每一段 AppleScript 只以表中的形式指稱目標視窗：不含 `window <數字>`，Safari 的 `front window` 只出現在比對 `id of front window` 的檢查裡。標記 `spec-example: document-targeting / references after the resolution`。驗證：`WindowLevelCommandsTests` 的對應測試
- [x] 7.2 測試先行：Example「window-level commands and the window number」（requirement「Window number resolved to its id at command start」）。表中八列：途中換順序仍指稱 `window id 5822`；途中關掉得到寫出 `window 2` 的 document-not-found 且沒有東西被關；`pdf`、`upload`、`screenshot` 釘住之後不含 `window 2`；讀不到 id 時一行 note 並以 `window 2` 進行；`--window 1 --profile Work` 整個指令只列舉一次。標記 `spec-example: document-targeting / window-level commands and the window number`。驗證：`WindowLevelCommandsTests` 的對應測試
- [x] 7.5 測試先行：Example「a tab opened during the enumeration, by command」（requirement「The enumeration decoder fails closed」）。視窗的列舉紀錄有兩個分頁、目前分頁序號 3 時，以 `--window-id 5822 --tab-in-window 1` 指定分頁 1：`pdf` 的匯出腳本與 `upload` 的一段腳本把它設成目前分頁，`close` 以位置關掉它且沒有任何分頁被設成目前分頁，`screenshot` 以 `backgroundTabNotCapturable` 拒絕。標記 `spec-example: window-enumeration / a tab opened during the enumeration, by command`。驗證：`WindowLevelCommandsTests` 的對應測試
- [x] 7.6 同一條 requirement 既有的 Example「rejected shapes」補上標記（#379 第 13 項的其中一筆）：`WindowEnumerationDecoderTests.testRejectedShapes` 補齊規格表的七列（加上空字串與布林的視窗 id 兩列）並帶標記 `spec-example: window-enumeration / rejected shapes`。驗證：該測試通過
- [x] 7.3 形狀檢查跟著更新（design「四個指令在開頭呼叫 pinWindowAtStart」）：`WindowPinCommandTests.testEveryCommandStructWithATargetPinsTheWindowExceptTheKnownOnes` 的已知例外拿掉 `CloseCommand`、`ScreenshotCommand`、`PdfCommand`。驗證：該測試通過；把任一個指令的 `pinWindowAtStart()` 拿掉時它失敗
- [x] 7.4 沒有呼叫端的舊函式移除：`performTabSwitchIfNeeded(window:tab:)`（由 `bringResolvedTabForward` 與各腳本取代）。驗證：`swift build` 通過；`WindowIndexResolverTests` 裡呼叫它的測試改成對 `bringResolvedTabForward` 斷言「沒有指名分頁時不送任何腳本」

## 8. 說明、文件與整體驗證

- [x] 8.1 [P] 使用者看得到的說明與文件符合新行為（含 `README.md` 的 multi-window 段落：改寫「`pdf`、`upload --native`、`close` 會把視窗拉到前面並切分頁」那一段，並更正「背景分頁會截到目前看得到的內容」為拒絕）：`--window` 與 `--window-id` 的 `--help` 不再寫「這四個指令留給 #353」；`pinWindowAtStart` 的註解更新；`CHANGELOG.md`（Unreleased）列出兩個行為改變（`close` 不再切換分頁、`upload` 有目標時在按鍵之前檢查最前面的視窗）與 `--window N` 在這四個指令上釘住；`CLAUDE.md` 的 multi-window 段落與 #354 段落的例外清單更新，並寫明沒有旗標時不變、Accessibility 那一側以 id 找視窗尚未做。驗證：內容檢查；`grep` 確認 `Sources/` 與 `CLAUDE.md` 沒有殘留「out of scope (safari-browser#353)」與「native paths are #353」
- [ ] 8.2 整套測試通過：`swift build --build-tests`，等 90 秒，`swift test --skip-build`（#380 的時序問題）。驗證：XCTest 與 Swift Testing 的失敗數為 0，計數寫在這一行下面
- [ ] 8.3 mutation 各做一次（改一處、跑相關測試、還原），每一次都有具名測試失敗：(a) 拿掉 `CloseCommand` 的 `pinWindowAtStart()`；(b) `close` 改回先切換分頁再關目前分頁；(c) 拿掉關閉腳本的網址比對；(d) 拿掉 dialog 腳本的 `verifyUploadOwner`；(e) `pdf` 匯出腳本的第一個區塊改回 `window N`；(f) `screenshot` 的讀取改回位置；(g) `open` 第 3 層改回兩個事件。驗證：每一項記下失敗的測試名稱，寫在這一行下面

真機驗收不在這份清單裡：它在 verify 之後、經維護者同意並事先告知才進行，項目是 issue #353 Diagnosis 的「Only a real Safari can show these」六項，結果寫回 issue。封存在 verify 之前，封存後的 tasks.md 不能再改，所以不列成勾選項。

- 實作紀錄（2026-11-13）：
  - 測試先行的落差：2.1 之外的測試需要新的函式簽名才能編譯，所以測試與實作在同一輪寫完，第一次執行就通過；「測試會失敗」改由 8.3 的 mutation 逐項證明，不是事前看到的 RED。
  - 1.6 另加一個測試 `WindowLevelTargetTests.testEveryWindowLevelScriptCompiles`：假 Safari 逐行讀腳本，AppleScript 語法錯了它看不出來，所以每一段新腳本另外交給 `NSAppleScript` 編譯（只編譯、不執行）。
  - `open` 的位置後備路徑改成先切分頁再拉視窗：原本先 `set index of window N to 1` 再 `set current tab of window N`，拉到前面之後 `window N` 已是另一個視窗（讀碼推得，未在真機重現）。
  - `README.md` 一併更新（8.1），原任務只列了 `CLAUDE.md` 與 `CHANGELOG.md`。
  - 提交後的修正（同日，封存之前）：`pdf` 與 native `upload` 原本只在目標是背景分頁時才比對網址，解析時已是目前分頁的不比對，與 requirement「第一段對分頁動手的腳本先比對」不符。改成只要解析指名了分頁就比對、不是目前分頁才切換（`bringTabForwardStatements`）；`upload` 的讀取與點擊改用 `.anchoredCurrentTab`，分頁不再是目前分頁就停，不重新解析。`open` 的腳本同樣改成「不是目前分頁才切」。`screenshot` 的釘住移進 `resolveCapture()`，`run()` 只讀它回傳的選項。4.3、4.1、3.1、6.1 的 Example 表格跟著改。
  - `--profile` 下釘住的視窗在解析前關掉時，原本只得到一行 note；改成列出該 profile 的分頁（`resolveWindowLevelTarget`），既有的 `ProfileScopedMissTranslationTests.testCloseUnderAProfile` 是抓到它的測試。
  - 規格範圍調整：不修改 `screenshot` 的〈Hidden window capture…〉與 `non-interference` 的〈Screenshot Accessibility path…〉（`-R`／`-l` 與沒有 Accessibility 時的行為，另開 #382）；新增修改 `window-enumeration` 的〈The enumeration decoder fails closed〉（它把 `close` 列為會切換分頁的指令）。

- ASSUMPTION（無人值守時的決定，verify 時請挑戰）：
  - 沒有目標旗標、沒有 `--profile` 時四個指令不變（#287 的範圍）。
  - `--window N` 在開頭釘不住時整段以位置進行，即使之後讀得到 id。
  - 網址比對不過就失敗，不重新解析重試；`--url-regex` 比對解析時讀到的完整網址。
  - `open` 第 3 層在一段腳本裡先切分頁再把視窗拉到前面（原本是先拉再切）。
  - `upload` 的 native 路徑改成單次解析（`resolveNativeTarget` 帶 `profile`），不再先 `resolveProfileScoped()`。
  - 標 `[P]` 以外的任務依序完成：它們改同一批介面。
  - `spectra` CLI 在 git clone 裡會定位到另一個 checkout，所以 `spectra analyze`／`validate`／`archive` 在只含規格目錄的鏡像中執行，產出再放回這個工作樹。
