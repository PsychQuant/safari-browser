## Context

五條路徑在解析目標之後，仍然以視窗的位置下後續的 Apple event（main `87712b1`）：

| 路徑 | 解析之後做的事 | 以位置指稱視窗的步驟 |
|---|---|---|
| `close` | `performTabSwitchIfNeeded(window: N, tab: T)`，再 `closeCurrentTab(window: N)` | 兩步都是；關的是切換之後的目前分頁（#348），切換本身也改變使用者看到的分頁 |
| `pdf` | 切換分頁，再跑 `exportScript(windowIndex: N)`（腳本開頭 `set pdfWindowID to id of window N`） | 切換分頁；匯出腳本開頭讀 id 的那一行釘住的是當下排在 N 的視窗 |
| `upload` 的 native 路徑 | 切換分頁、`getCurrentURL(.windowIndex(N))`、在 `.forWindow(N)` 點 file input、`nativeDialogScript(window: N)` | 四步都是；dialog 腳本送出第一個按鍵之前不檢查最前面的視窗是不是解析到的那一個 |
| `screenshot`（有目標旗標） | `getWindowIDViaAX(windowIndex: N)`：`id of window N`，再讀 `bounds`／`name of window N` | 兩次以位置讀取 |
| `open` 帶出既有分頁 | `findExactMatch` 丟掉列舉讀到的 id；`detectWindowSpace(windowIndex: N)`、`activateWindow(N)`、`performTabSwitchIfNeeded(N, T)` | Space 判斷、拉到前面、切分頁，共三個事件 |

解析結果 `ResolvedWindowTarget` 對每一種旗標都帶著 `windowID`：`--url` 系列、`--tab`、`--document`、`--window-id`、`--profile` 來自列舉，`--window N` 與沒有旗標來自 `readWindowID`。呼叫端沒有用它。

前置條件已經就位：

- #354 的 `TargetOptions.pinWindowAtStart()` 在指令開頭把 `--window N` 換成 `--window-id W`，並把 N 記在 `pinnedFrom`，讓失敗訊息寫得出 `window N (window id W at command start)`。它的註解與〈Window number resolved to its id at command start〉的例外清單都寫明這四個指令留給 #353。
- #355 之後，列舉紀錄沒有 id 只會是零分頁的視窗；`readWindowID` 讀不到只會是視窗不存在或一秒內沒有回答。
- `runTargetedAppleScript` 已經會把「找不到物件」轉成 `documentNotFound`，對 `.windowID(_, _, pinnedFrom)` 會寫出 N。

限制：

- 維護者的決定（issue 上的 Decision）：讀不到 id 照 #354 的規則；#348 在這裡修；在 Accessibility／CoreGraphics 那一側以 id 找視窗之前，要先在真的 Safari 上確認 AppleScript 的視窗 id 等於 CGWindowID；真機驗收在實作與 verify 之後、開始前先告知。
- `pdf` 與 `upload` 的 dialog 腳本由 `runFileDialogScript` 直接交給 `/usr/bin/osascript`，不經 `DaemonRequestContext.appleScriptRunner`；`ensureSystemEventsLive` 同樣直接執行 `osascript`。`PdfCommand.nativeExporter` 取代的是整個 native 匯出（含解析）。`focusExistingTab` 直接呼叫 CGS 與 Accessibility 讀 Space。`getWindowIDViaAX` 需要 `AXIsProcessTrusted()`。單元測試因此到不了按鍵、截圖與 Accessibility 的行為。

## Goals / Non-Goals

**Goals:**

- 五條路徑在解析之後只以 `window id W` 指稱目標視窗；視窗不見時在動手之前失敗。
- `close` 關的是解析出來的那個分頁，不切換分頁（#348）。
- `--window N` 在這四個指令上與其他指令一致：開頭釘住一次，失敗訊息寫出 N。
- 以網址比對出來的分頁，在第一段對它動手的 AppleScript 裡重新確認。
- 每一條新增或修改的 requirement 都有可執行的檢查；到不了的部分明寫 `No executable check:`。

**Non-Goals:**

- **沒有目標旗標的行為**。沒有任何目標旗標、也沒有 `--profile` 時，四個指令照舊對最前面的視窗動作，腳本文字不變。要不要在開頭釘住最前面的視窗是 #287 的問題。
- **在 Accessibility／CoreGraphics 那一側以 id 找視窗**（`screenshot` 以 `_AXUIElementGetWindow` 等於 `W` 找視窗、`open` 的 Space 判斷以 id 找視窗）。這要先有真機上「AppleScript 視窗 id 等於 CGWindowID」的確認，排在驗收之後另案處理。本變更只把 AppleScript 那一側的位置讀取換成 id。
- **分頁的身分**。Safari 的 AppleScript 沒有分頁 id（#188）；`tab T of window id W` 的 T 仍是視窗內的位置。
- **`screenshot` 的旗標判斷**（`--url-exact`、`--url-endswith`、`--url-regex`、只有 `--profile`、`--tab-in-window` 不被當成有目標）是 #233 的範圍，本變更不動那一行。
- **`screenshot` 規格與程式的既有落差**：規格寫 `screencapture -R`、程式用 `-l`；規格寫沒有 Accessibility 時有目標的截圖會退回舊路徑，程式是直接報錯。兩者都與視窗 id 無關，另開 issue 處理，本變更不修改那兩條 requirement。
- **比對失敗後重新解析再試一次**。#79 對 JavaScript 派送這樣做；這裡的動作不可逆（關分頁）或會送出按鍵，比對不過就失敗。
- 不新增任何使用者可見的旗標。

## Decisions

### 視窗層級的指令以 ActingWindow 指稱目標視窗

新增 `SafariBridge.ActingWindow`，兩個 case：`.id(W)` 產生 `window id W`，`.position(N)` 產生 `window N`。由一個純函式從解析結果決定：

| 指令拿到的目標（釘住之後） | ActingWindow |
|---|---|
| 沒有目標旗標、沒有 `--profile` | `.position(1)`（腳本與今天逐字相同） |
| `--window N` 仍是位置（開頭讀不到 id，#354 的 note 已經印出） | `.position(N)` |
| 其他，而且解析結果有視窗 id | `.id(W)` |
| 其他，而且解析結果沒有視窗 id（零分頁視窗的列舉紀錄） | `.position(resolved.windowIndex)` |

五條路徑產生腳本的函式都改收 `ActingWindow`（或它的參照字串），所以「有 id 就用 id、沒有就用位置」只有一個地方決定，位置形式與 id 形式是同一批腳本。

不採用的做法：只要解析結果有 id 就一律用 id。`resolveNativeTarget(.frontWindow)` 也會讀到 id，這樣會順手把沒有旗標的路徑釘在開頭時最前面的視窗，那是 #287 還沒決定的事。

ASSUMPTION: `--window N` 在開頭釘不住時，即使之後 `resolveNativeTarget` 自己讀到了 id，仍然整段以位置進行。理由是 #354 的 note 已經告訴使用者「每一步都以位置查」，而且規格要求這種情況與釘住之前逐字相同。

### 四個指令在開頭呼叫 pinWindowAtStart

`close`、`screenshot`、`pdf`、`upload` 的 native 路徑各在自己的參數檢查之後、第一個 Apple event 之前呼叫 `pinWindowAtStart()`，之後只用回傳的那一份 `TargetOptions`：

- `close`：`run()` 的第一行。
- `pdf`：`--allow-hid` 的拒絕與目的地檢查都不碰 Safari，維持在前面；釘住放在 native 匯出的開頭、解析目標之前。
- `upload`：檔案存在的檢查維持在前面（已在〈Window number resolved…〉的七項檢查裡）；native 路徑在解析目標之前釘住。
- `screenshot`：session、Screen Recording、Accessibility 三項事前檢查不碰 Safari，維持在前面；之後釘住。`--full` 讀頁面尺寸用的文件目標也取自釘住後的那一份。

`--profile` 下，開頭那一次列舉就是整個指令的 profile 檢查（#354 的規則）。釘住的結果帶著「已對過這個 profile」的紀錄時，這四個指令之後解析目標不再帶 `profile`，所以釘住的 `--window N` 只多一個讀位置的小查詢，不再列舉第二次；錯誤訊息仍然用使用者給的 profile。

`WindowPinCommandTests` 的形狀檢查裡，`CloseCommand`、`ScreenshotCommand`、`PdfCommand` 三筆「已知例外」拿掉。

### close 以一段腳本關閉解析出來的分頁

`close` 不再呼叫切換分頁。它送出一段 AppleScript：

1. 沒有任何視窗、或目標視窗沒有分頁時，以原本的文字報錯（#93 的零分頁檢查保留）。
2. 解析出特定分頁時（`--url` 系列、`--tab`、`--document`、`--tab-in-window`；取 `anchorTabIndex`，即使那個分頁剛好是目前分頁），`set _t to tab T of <視窗>`，必要時比對網址，然後 `close _t`。
3. 否則 `close current tab of <視窗>`。

`<視窗>` 是 `ActingWindow` 的參照，所以讀不到 id 時同一段腳本以 `window N` 進行：#348 的修正不依賴 id 讀不讀得到。腳本經 `runTargetedAppleScript` 執行，視窗不見時得到 `documentNotFound`。

不採用的做法：保留切換分頁，只把兩步改成以 id 指稱。那樣仍然改變使用者看到的分頁，而且「目前分頁」在兩個事件之間可以再變。

### 以網址比對的目標在動手前重新確認

目標由網址旗標比對出來時，第一段對那個分頁動手的 AppleScript 先確認它仍然符合，再動手，兩者在同一段：

- `--url`、`--url-exact`、`--url-endswith`：沿用 #79 的 `urlGuardClause(for:)`，以使用者給的條件、區分大小寫比對。
- `--url-regex`：AppleScript 沒有正規表示式，改成比對「分頁現在的網址等於解析時讀到的網址」；網址超過 2,000 個字元時比對前 2,000 個字元。為此 `ResolvedWindowTarget` 多一個欄位 `matchedURL`，由 `pickNativeTarget` 的網址分支與 `--first-match` 的後備路徑填入。
- `open` 帶出既有分頁：比對分頁的網址等於要開的網址。

比對不過時腳本以錯誤編號 9001 結束，Swift 端轉成新的 `SafariBrowserError.targetChangedBeforeActing`，訊息說明沒有對那個分頁做任何事。不重新解析、不重試。

不用既有的 `targetTabChanged`：它的訊息寫「after one automatic re-resolve」，這裡沒有重試，沿用會是不實的陳述。

不採用的做法：一律比對解析時讀到的完整網址。頁面自己改網址（hash、query）是常態，解析到動手之間只要變一次就會失敗，而使用者指定目標的條件是他給的樣式，不是那一刻的完整網址。只有正規表示式因為 AppleScript 做不到才退到完整網址。

`--tab`、`--document`、`--tab-in-window` 指定的是位置，不比對網址。

### 視窗不見時的錯誤沿用 pinWindowAtStart 的寫法

新增純函式 `SafariBridge.actedTarget(for:named:profile:)`，把解析結果換成後續呼叫與錯誤訊息用的 `TargetDocument`：

- 釘住或使用者輸入的 `.windowID(W, tab, pinnedFrom)` 原樣保留（`pinnedFrom` 不丟），所以釘住的視窗不見時，訊息是 `window N (window id W at command start)`。
- 網址、`--tab`、`--document` 的目標變成 `.resolvedTab(W, T, rematch, profile)`。
- 位置形式維持 `.windowIndex(N)`／`.windowTab(N, T)`。

`close`、`screenshot` 的讀取、`open` 的腳本、`upload` 的切換分頁與事前檢查都經 `runTargetedAppleScript`，直接得到 `documentNotFound`。`pdf` 的匯出腳本與 `upload` 的 dialog 腳本不經它，所以這兩段以 id 進行的腳本開頭先檢查 `exists window id W`，不在就以固定標記 `SB_WINDOW_GONE`（錯誤編號 9002）結束；Swift 端看到這個標記，產生與 `runTargetedAppleScript` 相同的錯誤。為此把 `runTargetedAppleScript` 裡「找不到物件」那一段抽成一個函式，兩邊共用。

### pdf 的切換分頁併進匯出腳本

`PdfCommand.exportScript` 改收 `ActingWindow`、要切換到的分頁（可無）與要比對的條件（可無）。以 id 進行時，第一個 `tell application "Safari"` 區塊依序：確認 `window id W` 存在、（有分頁時）取 `tab T of window id W`、比對網址、把它設成目前分頁、讀目前分頁的網址、`set index of window id W to 1`、`activate`。之後的 `verifyPDFOwner` 本來就以 id 比對，不變。切換分頁原本是匯出腳本之前的另一個事件，現在在同一段裡。

位置形式（`.position(N)`）維持腳本開頭 `set pdfWindowID to id of window N` 的寫法；有分頁要切時同樣併進這一段。

### upload 在每個按鍵之前檢查最前面的視窗

native 路徑解析之後：

1. 需要切換分頁時，一個事件以 id 切換（`set current tab of window id W to tab T of window id W`），網址比對在同一段。
2. 事前檢查（讀目前網址）與點擊 file input 用 `actedTarget` 的結果，所以是 `window id W` 或 `tab T of window id W`。
3. dialog 腳本以 id 把視窗拉到前面。腳本定義 handler `verifyUploadOwner`：`window id W` 不存在、或 `id of front window` 不是 `W` 時報錯，訊息說明沒有送出按鍵、並提示先關掉已經開著的檔案對話框。這個檢查放在等到 sheet 出現之後，以及 `fileDialogNavigationScript` 裡 `pdf` 檢查擁有者的每一個位置（第一個按鍵之前、每次等待的迴圈裡、貼上與 Return 之前、按下確認之前）。

為此 `fileDialogNavigationScript` 多一個參數 `ownerGuard`：`pdf` 傳它原本的兩行，`upload` 以 id 進行時傳 `my verifyUploadOwner(W)`，其他情況是空字串。`pdf` 與沒有 guard 的 `upload` 產生的文字與現在逐字相同。

`upload` 的 native 路徑改成與 `pdf`、`close` 一樣呼叫 `resolveNativeTarget(from:firstMatch:warnWriter:profile:)`，不再先 `resolveProfileScoped()` 再解析一次；`--profile` 下少一次列舉，結果相同。

位置形式與沒有目標旗標時不加 `verifyUploadOwner`，腳本與現在相同。

### screenshot 以 id 讀 bounds 與標題

`resolveWindowForCapture` 改收 `ActingWindow?`（`nil` 是沒有目標旗標）與錯誤用的目標。以 id 進行時，原本「確認視窗存在」與「讀 bounds 與標題」的兩個事件合成一段經 `runTargetedAppleScript` 的腳本，讀 `window id W`；視窗不見就是 `documentNotFound`。之後照舊：以 bounds 與標題在 Accessibility 的視窗清單裡找出唯一的視窗，取它的 CGWindowID 交給 `screencapture -l`。位置形式維持現在的兩段腳本。不拉視窗、不切分頁；背景分頁照舊拒絕。

Choice Default Record（Diagnosis 記載）的選項 (1)：不在這裡以 id 在 Accessibility 那一側找視窗。

### open 帶出既有分頁以 id 在一段腳本完成

`findExactMatch` 的回傳值多帶 `windowID`。`focusExistingTab` 多收 `windowID` 與一個可注入的 Space 讀取（預設是現在的 `getCurrentSpace()`／`detectWindowSpace(windowIndex:)`）：

- 第 2 層（同視窗的背景分頁）：一段腳本，比對網址後 `set current tab of window id W to tab T of window id W`。
- 第 3 層（同一個 Space 的另一個視窗）：一段腳本，比對網址、（需要時）切分頁、`set index of window id W to 1`、`activate`。原本是拉到前面與切分頁兩個事件；順序改成先切分頁再拉到前面，與 `pdf` 一致。
- 第 1、4 層不變。Space 判斷不變（仍以 Accessibility 清單的位置找視窗）。
- 沒有 id 時走現在的位置形式。

比對不過是 `targetChangedBeforeActing`，視窗不見是 `documentNotFound`；兩者都不改開新分頁。

### 測試只到腳本邊界

沒有任何新測試可以執行 `/usr/bin/osascript`、System Events、`screencapture` 或 Accessibility。做法：

- `close` 整個指令可以在 `PinFakeSafari` 上執行（它只走 `appleScriptRunner`）。假 Safari 加兩項能力：套用關閉（記下關了哪個視窗的哪個分頁）、以及照腳本裡的網址比對與 `SB_TARGET_CHANGED` 決定要不要報錯。
- `pdf`：把「釘住、解析、產生匯出腳本」抽成指令的一個方法，回傳腳本文字；`exportNative` 只剩把它交給 `runFileDialogScript`。測試執行前者。
- `upload`：把「釘住、解析、切換分頁、事前檢查、產生 effects」抽成回傳計畫的方法；`ensureSystemEventsLive` 與執行 effects 留在後半。測試執行前者，effects 的執行已有可注入的 `runNativeUploadEffects`。
- `screenshot`：把「釘住、解析、拒絕背景分頁」抽成方法；以 id 讀 bounds 與標題的那一段可以在假 Safari 上執行。Accessibility 的比對與實際截圖沒有可執行的檢查。
- `open`：以注入的 Space 讀取執行 `focusExistingTab`。
- 腳本產生器都是純函式，另有形狀測試（以 id 進行時不含 `window <數字>`；`front window` 只出現在 System Events 的區塊與 id 比對）。

`upload` 的「最前面不是 W 就不送按鍵」寫在 AppleScript 裡，假 Safari 不執行它；可執行的檢查是腳本形狀（每個 `keystroke` 與確認之前都有 `verifyUploadOwner`）。實際行為列在真機驗收。

## Implementation Contract

**行為**

- `close`、`pdf`、`upload`（native 路徑）、`screenshot` 帶任何目標旗標或 `--profile` 時，以及 `open` 帶出既有分頁時：解析之後送出的每一段 AppleScript 以 `window id W` 指稱目標視窗；不含 `window <n>`；`front window` 只用於比對 `id of front window` 與 System Events 區塊內對 sheet 的操作。
- `--window N` 在這四個指令上於開頭釘住一次；讀不到 id 時印 #354 的那一行 note 並整段以位置進行。
- `close` 送出一段關閉腳本，不送 `set current tab`。目標是背景分頁時，那個視窗的目前分頁不變。
- 由網址旗標比對出來的分頁，在第一段對它動手的腳本裡先確認；不符合時指令以 `targetChangedBeforeActing` 失敗，沒有分頁被關、沒有分頁被切換、沒有視窗被拉到前面、沒有按鍵送出。
- 目標視窗在某一步之前關掉：`documentNotFound`；由 `--window N` 釘住時 pattern 以 `window N (window id W at command start)` 開頭。
- `upload` 以 id 進行時，dialog 腳本在第一個按鍵之前與之後每一個按鍵、每一次確認之前檢查 `id of front window` 是 `W`。
- 沒有目標旗標、沒有 `--profile` 時，四個指令送出的腳本與 `87712b1` 逐字相同。

**介面**

- `SafariBridge.ActingWindow`（`.id(Int)`、`.position(Int)`、`reference`）；`actingWindow(for:named:profile:)`、`actedTarget(for:named:profile:)`。
- `ResolvedWindowTarget.matchedURL: String?`（預設 `nil`，既有建構處不必改）。
- `SafariBridge.closeTabScript(windowReference:tab:guardClause:)`、`closeResolvedTab(_:named:profile:)`，取代 `closeCurrentTab(window:profile:)`／`closeCurrentTabScript(windowRef:)`。
- `SafariBridge.tabSwitchScript(windowReference:tab:guardClause:)`、`switchToResolvedTab(_:named:profile:)`，取代 `performTabSwitchIfNeeded(window:tab:)`。
- `SafariBridge.tabGuardClause(named:matchedURL:)`：回傳比對用的 AppleScript 片段或 `nil`。
- `PdfCommand.exportScript(path:window:switchToTab:guardClause:timeout:)`；`UploadCommand.nativeDialogScript(path:window:)` 與 `nativeUploadEffects(selector:path:window:)` 的 `window` 改成 `ActingWindow?`。
- `SafariBridge.fileDialogNavigationScript(path:pdfSave:ownerGuard:)`。
- `SafariBridge.resolveWindowForCapture(window:missTarget:session:resolve:)`，`window` 是 `ActingWindow?`。
- `SafariBridge.findExactMatch(url:in:)` 的回傳 tuple 多一個 `windowID: Int?`；`focusExistingTab(window:tabInWindow:isCurrent:url:windowID:warnWriter:spaces:)`。
- `SafariBrowserError.targetChangedBeforeActing(expected: String)`。
- 腳本內的標記：`SB_TARGET_CHANGED`（9001，既有）、`SB_WINDOW_GONE`（9002，新增）。

**失敗方式**

- 比對不過：`targetChangedBeforeActing`，訊息含目標的描述與「沒有對它做任何事」。
- 視窗不見：`documentNotFound`，清單與提示照〈Document not found surfaces discoverable error〉對 `.windowID`／`.resolvedTab` 的既有規則。
- `upload` 最前面的視窗不是 `W`：AppleScript 錯誤，訊息說明沒有送出按鍵並提示關掉檔案對話框；`staleDialogGuidance` 不適用。
- 讀不到 id：不是錯誤，照位置進行。

**驗收**

- `swift test` 全過；tasks.md 列出的每個 Example 各有一個帶 `spec-example:` 標記的測試。
- mutation：各拿掉一次（`close` 的釘住、`close` 改回切換分頁、網址比對、`upload` 的 `verifyUploadOwner`、`pdf` 腳本改回位置），每一次都有具名測試失敗。
- 真機驗收（維護者同意後，開始前告知）照 issue Diagnosis 的清單進行，結果寫回 issue；它不是 tasks.md 的勾選項，因為封存在 verify 之前。

**範圍邊界**

- 範圍內：上述五條路徑、八個 capability 的規格、`--window`／`--window-id` 的說明、`CLAUDE.md`、`CHANGELOG.md`。
- 範圍外：Non-Goals 所列；`upload` 的 JavaScript 路徑（#354 已釘住）；`tab`、`tabs`、`open --new-tab`（各自已經以 id 進行）；Save As 面板（#358）。

## Risks / Trade-offs

- [`close` 不再切換分頁] 依賴「關之前先切過去」這個副作用的呼叫者會看到差異 → 目前沒有已知的呼叫者；寫進 CHANGELOG 的行為改變。
- [`upload` 新增的檢查把原本「按鍵送進別的視窗」的執行變成失敗] 這是要的結果，但在多視窗的 session 裡是行為改變，而且失敗時檔案對話框還開著 → 錯誤訊息明寫沒有送出按鍵、要先關掉對話框；寫進 CHANGELOG。
- [檔案對話框開著時 `id of front window` 是不是仍等於 `W` 只有真機知道] `pdf` 的 `verifyPDFOwner` 在儲存 sheet 開著時做同樣的比對 → 列入真機驗收第 4 項；若不成立，`upload` 的每一次有目標的 native 上傳都會失敗，那會在驗收時立刻看到。
- [`set index of window id W to 1` 與位置形式的效果是否相同只有真機知道] → 真機驗收第 4 項。
- [`close tab T of window id W` 關背景分頁時是否不影響目前分頁與視窗順序只有真機知道] → 真機驗收第 3 項。
- [網址比對對 `--first-match` 的多重符合較寬] T 的位置換成另一個同樣符合的分頁時會通過 → 使用者以 `--first-match` 接受了「任一個符合的」；分頁沒有 id（#188）是根本限制，寫進規格。
- [正規表示式的目標在解析到動手之間改了網址就失敗] 比其他旗標嚴格 → 這是 AppleScript 沒有正規表示式的代價，方向是不動手。
- [測試到不了按鍵、截圖、Accessibility] 假 Safari 回答的是測試寫的內容 → 腳本形狀測試加真機驗收；規格以 `No executable check:` 標出沒有檢查的部分。
- [改寫既有的腳本形狀測試時可能把檢查改弱] → 逐一改成新的形狀而不刪除；mutation 檢查確認仍然抓得到。
- [一個 change 碰八個 capability] MODIFIED 會整段取代 requirement → 每一段從現行規格逐字複製後只改必要的句子，以腳本比對差異。
