## Problem

Safari 的視窗列舉（`SafariBridge.listAllWindowsScript`，由 `parseWindowEnumeration` 解析）用 GS（U+001D）分欄、RS（U+001E）分筆，而分頁標題與視窗名稱（視窗名稱帶著目前分頁的標題）原樣放進去。網頁可以控制標題，所以網頁能偽造整筆紀錄：在真的 Safari 上，一個標題就讓 `documents --json` 對 3 個分頁列出 7 列（#355 的量測留言），也能改寫另一個視窗的 profile 與 window id，而 identity-anchored 目標（#79）以 window id 定址。

第一版修法（fac190c）在 AppleScript 裡逐字元把 28–31 換成 U+FFFD。verify 第一輪量到它是平方時間：一個很長的標題（或一段很長的組合字元序列）就能讓每次列舉超過 30 秒的程序逾時與 15 秒的 daemon client 逾時，並卡住 daemon 的 `@MainActor` 編譯快取。維護者在 2026-11-09 選了方案 1：列舉改回傳結構化資料，不再用分隔字元串接文字。

## Root Cause

列舉把紀錄框架（分隔字元）與網頁控制的文字放在同一個頻道，且沒有跳脫；解析器接受分隔字元切出來的任何紀錄。只要框架是 in-band 的，修法就得在 AppleScript 裡逐字元處理網頁文字，而 AppleScript 的文字處理在這些輸入上是平方時間。

## Proposed Solution

- 列舉腳本回傳 AppleScript list：每個視窗一筆 `{w, winID, winName, currentIdx, urls, names}`，`urls` 與 `names` 就是 #180 的整批讀取結果，原樣放進去；0 分頁視窗回傳同樣形狀的 `{w, winID, winName, 0, {}, {}}`；沒有視窗時回傳 `{}`。網頁文字只出現在字串值裡，AppleScript 不對它做任何逐字元的事，也不再有逐分頁的串接迴圈。
- 線上格式是 AppleScript 的 source form（`osascript -s s` 印出的樣子：字串加雙引號，只跳脫 `"` 與 `\`）。stateless 路徑用 `osascript -s s -e`；daemon 路徑（`applescript.execute` 與 `exec.runScript` 的 in-process runner）把 `NSAppleEventDescriptor` 轉成同一種 source form。Swift 端只有一個解碼器，兩條路徑解出的結果相同。
- 解碼器失敗即關閉：形狀不對、型別不對、`urls` 與 `names` 長度不同、視窗編號不連續、目前分頁超出範圍、window id 重複、空字串，都丟 `windowEnumerationCorrupt`，訊息只寫位置、數量與型別，不寫任何網頁文字（#227）。
- 移除 fac190c 的替換 handler 與舊的 GS/RS 解析器（含 4/5/6 欄的舊格式相容）。恢復 6c07d65 為了這次重做而拿掉的 `windowEnumerationCorrupt` 相關文字。
- 測試假資料改由一個測試 helper 產生 source form 文字，日後格式再變只改一處。

## Non-Goals

（詳見 design.md 的 Goals / Non-Goals。）不修 #363（screenshot 以 U+001F 框住視窗名稱）、#366（`tabURLs` 以 GS 串接）、#364（標題含 ` — ` 冒充 profile）。

## Success Criteria

- 標題、網址或視窗名稱裡的任何字元（含 U+001C–U+001F、`"`、`\`、CR、LF、NUL、組合字元）都不會產生、刪除或改變任何一列，也不會改變任何視窗的 profile 或 window id；`documents --json` 的鍵與列的形狀不變。
- 10^5 與 10^6 字元的標題，列舉的成本與標題長度成線性（量測數字記在 design.md）。
- 同一個 AppleScript 結果，經 `osascript -s s` 與經 daemon 的 descriptor 轉換，產生位元組相同的文字（以不需 Safari 的測試釘住）。
- 解碼器拒絕的輸出讓指令失敗，錯誤訊息不含網頁文字；空字串不再被當成「沒有視窗」。
- 沒有新增任何 Apple event；#180 的整批讀取、第二次 URL 讀取的 `considering case` 比較、逐分頁的退路、0 分頁視窗的空殼紀錄都保留。

## Capabilities

### New Capabilities

- `window-enumeration`: Safari 視窗與分頁列舉的線上格式（結構化 source form）、兩條執行路徑的一致性、解碼器的檢查與失敗方式。

### Modified Capabilities

- `document-targeting`: 「Document not found surfaces discoverable error」的列舉失敗說明恢復「a malformed list」這一類。
- `script-exec`: 「Daemon-routed execution when available」加上條件：daemon 的握手沒有宣告 `sourceForm` 時不送 `exec.runScript`，改走逐步執行（verify 第四輪）。
- `persistent-daemon`: daemon 在 v2 握手的 `protocol` 物件以選用的 `capabilities` 陣列宣告 `"sourceForm"`；client 在送出 source form 請求與 `exec.runScript` 之前檢查，沒有宣告就改走 stateless／逐步執行（verify 第三輪）。

## Impact

- Affected specs: `window-enumeration`（新）、`document-targeting`（修改）、`persistent-daemon`（修改）、`script-exec`（修改）
- Affected code:
  - `Sources/SafariBrowser/SafariBridge.swift`（`listAllWindowsScript`、`listAllWindows`、`parseWindowEnumeration` → `decodeWindowEnumeration`、新的 `runAppleScriptSourceForm`、`runProcessWithTimeout` 的呼叫參數）
  - `Sources/SafariBrowser/Utilities/AppleScriptSourceForm.swift`（新：值型別、解析器、descriptor 轉換）
  - `Sources/SafariBrowser/Utilities/Errors.swift`（`windowEnumerationCorrupt`、`enumerationFailureNote` 的種類）
  - `Sources/SafariBrowser/Daemon/DaemonRouter.swift`、`Daemon/DaemonDispatch.swift`、`Daemon/PreCompiledScripts.swift`、`Daemon/DaemonRequestContext.swift`（`resultForm` 參數、source form 的 in-process runner）
  - Tests：新的 `AppleScriptSourceFormTests`、`WindowEnumerationDecoderTests`、`WindowEnumerationTransportTests`、`Tests/SafariBrowserTests/FakeEnumeration.swift`；改寫 `ZeroTabWindowGuardTests`、`WindowEnumerationBatchingTests`、`EnumerationFailureNoteTests` 與所有以 GS/RS 假造列舉的測試（`DialogListingRenderingTests`、`WindowIndexResolverTests`、`ResolverConvergenceTests`、`WindowIDCommandTests`、`JSCommandRoundTripTests`、`TargetIdentityTests`、`PreCompiledScriptsTests`、`ExecSharedTargetTests`、`WindowPinFakeSafari`、`MissFakeSafari`）
  - `CHANGELOG.md`、`CLAUDE.md`、`openspec/specs/document-targeting/spec.md`
