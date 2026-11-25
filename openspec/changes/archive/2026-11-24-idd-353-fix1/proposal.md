## Problem

`idd-353-window-primitives-by-window-id` 讓 `close`、`pdf`、`screenshot`、native `upload` 與 `open` 的「顯示既有分頁」在解析目標之後以 `window id W` 指稱視窗。#353 的第一輪驗證（issue 上的 Verify 報告，共 32 列）指出：解析之後的某些步驟仍然用別的方式找目標、某些檢查只做一次、有幾種失敗的文字與實際發生的事不符，另有一條既有的 requirement 仍然寫著這次變更之前的行為。

1. `screenshot --full`／`--element` 的頁面步驟（讀尺寸、捲動與還原、讀元素位置）把旗標重新解析一次，所以可能在另一個視窗或分頁上執行，而截到的是解析出來的那個視窗。
2. native `upload` 在分頁腳本之後讀到的網址沒有與旗標比對；對話框腳本不再確認分頁；擁有者檢查只比對視窗 id，不看頁面網址，也不問 Safari 是不是最前面的應用程式（System Events 把按鍵送給最前面的應用程式）。
3. 解析指到的分頁已經不在（視窗還開著）時，`pdf` 與 `upload` 的腳本得到 Safari 的「invalid index」，不是 document-not-found。
4. target-changed 錯誤一律說「什麼都沒做」，但 `upload` 在那之前可能已經切了分頁、或已經按了檔案欄位。
5. 腳本回報的三種狀況以錯誤文字裡的字串辨認；System Events 的錯誤文字可能帶有視窗名稱，也就是網頁標題。
6. `--profile` 之下，以視窗 id 指稱的目標在後續步驟找不到時只給一句說明，沒有列出該 profile 的視窗。
7. `open` 以位置顯示既有分頁時（列舉紀錄沒有視窗 id）送兩段腳本、不檢查網址；「已把視窗拉到最前面」的警告在動作之前就寫出。
8. `pdf` 在目標找不到、什麼都還沒做的時候，也印出「可能還有儲存對話框開著」的提示。
9. 使用者輸入的 `--window-id` 在列舉紀錄沒有 id 時退回以位置指稱。
10. document-targeting 的「Document not found surfaces discoverable error」仍寫 `close` 的 miss 重複「解析器產生的 Safari 視窗編號」、native `upload` 與 `screenshot` 的 miss 不分 profile、「只有 #353 會移除」。
11. 「Window-level commands act on the window they resolved」的封閉清單沒有列出 `screenshot` 不把 `--profile`（單獨）、`--url-exact`、`--url-endswith`、`--url-regex` 當成目標這件既有的事（#233），也沒有說以位置指稱時少了哪些檢查。

## Root Cause

第一個變更把「解析之後以 id 指稱視窗」寫成 requirement，但只描述了送出的第一段腳本；之後的每一步（讀、點、對話框腳本、頁面步驟）要再確認什麼、失敗時要說什麼，沒有寫下來，實作也就只做到第一段。測試多半重建了正式程式的接線（自己呼叫 `runNativeUploadEffects`、`readCaptureGeometry`、`focusExistingTab`），所以把接線改錯也不會失敗；假 Safari 以 Swift 的字串比較判斷網址，看不出腳本少了 `considering case`。

## Proposed Solution

- 每個後續步驟各自確認：
  - `screenshot` 的頁面步驟在解析固定下來的文件上執行（`document of window id W`，或該分頁、且只在它仍是目前分頁時），不再解析旗標。
  - `upload` 讀到的網址要符合旗標；對話框腳本在拉視窗之前再確認一次分頁（還在、網址檢查通過、仍是目前分頁），並讀下頁面網址；擁有者檢查依序看視窗還在、是 Safari 最前面的視窗、最前面的視窗仍顯示那個網址、Safari 是最前面的應用程式。
  - 視窗的分頁數少於解析指到的位置時，腳本以錯誤編號 9003 結束，指令回報 document-not-found。
- target-changed 錯誤帶著發生的階段（動作之前／`upload` 切過分頁之後／`upload` 點過檔案欄位之後），文字照實說已經做了什麼。
- 三種狀況以錯誤結尾的編號（9001、9002、9003）辨認，不看文字。
- `--profile` 之下以視窗 id 指稱的 miss 列出該 profile 的視窗（視窗還在而分頁不在時列出該視窗的分頁）。
- `open` 以位置顯示時是同一段腳本、同樣的檢查；警告在動作之後才寫。
- `pdf` 的提示只在可能留下對話框的錯誤之後印出。
- 使用者輸入的視窗 id 一律以 id 指稱。
- 規格：改寫上面第 10、11 點的兩條 requirement，補上各 capability 的後續檢查與新的 Example。
- 測試：改成執行正式程式的函式（`runNativeUpload`、`ScreenshotCommand.captureWindow`、`OpenCommand.revealExisting`），外部相依以參數替換；假 Safari 在 `considering case` 之外不分大小寫。

## Non-Goals

- `screenshot` 在 Accessibility／CoreGraphics 那一側以邊界與標題找視窗、`open` 的 Space 檢查以位置找視窗：留給 #391（要先在真的 Safari 上確認 AppleScript 的視窗 id 等於 CGWindowID）。
- `screenshot` 不把 `--profile`（單獨）、`--url-exact`、`--url-endswith`、`--url-regex` 當成目標：#233，這裡只把它寫進封閉清單；唯一的行為變更是這四個旗標之下，`--full`／`--element` 的頁面步驟改為在擷取的那個視窗（最前面的視窗）上執行，不再另外解析旗標。
- 以位置指稱視窗的 native `upload`（視窗 id 讀不到時）不加「仍是目前分頁」的檢查，對話框腳本維持原樣：位置本身就不是身分，加了檢查也只是檢查另一個位置。
- 對話框或儲存面板出現之後視窗消失：維持腳本自己的錯誤（不再送出按鍵），不改成 document-not-found；規格照實寫。
- 網址檢查比 Swift 的比對寬鬆的情形（看不見的字元）、「Go to Folder」裡的相對路徑、`verifyPDFOwner` 的大小寫：另開 follow-up。
- 沒有設計文件：這是照驗證報告逐列修正，沒有新的設計選擇；三個取捨寫在上面與 issue 的 Implementation Plan（fix round 1）。

## Success Criteria

- 每個新增或修改的 Example 都有帶 `spec-example:` 標記的測試，且該測試逐列斷言。
- 把這一輪的每個行為各退回一次（31 個變異），都有具名的測試失敗。
- `swift test` 全部通過；沒有測試執行 `/usr/bin/osascript`、System Events、`screencapture`、Accessibility 或真的 Safari。

## Impact

- Affected specs: `document-targeting`（三條 requirement）、`file-upload`、`screenshot`、`pdf-export`、`human-emulation`
- Affected code:
  - `Sources/SafariBrowser/SafariBridge+WindowLevel.swift`
  - `Sources/SafariBrowser/SafariBridge.swift`
  - `Sources/SafariBrowser/Utilities/Errors.swift`
  - `Sources/SafariBrowser/Commands/UploadCommand.swift`
  - `Sources/SafariBrowser/Commands/PdfCommand.swift`
  - `Sources/SafariBrowser/Commands/ScreenshotCommand.swift`
  - `Sources/SafariBrowser/Commands/OpenCommand.swift`
  - `Sources/SafariBrowser/Commands/CloseCommand.swift`
  - `Tests/SafariBrowserTests/WindowLevelFakeSafari.swift`
  - `Tests/SafariBrowserTests/WindowLevelTargetTests.swift`
  - `Tests/SafariBrowserTests/WindowLevelNativeDialogTests.swift`
  - `Tests/SafariBrowserTests/WindowLevelCaptureAndFocusTests.swift`
  - `Tests/SafariBrowserTests/WindowLevelCommandsTests.swift`
  - `Tests/SafariBrowserTests/CommandParsingTests.swift`
  - `Tests/SafariBrowserTests/WindowEnumerationDecoderTests.swift`
  - `README.md`、`CHANGELOG.md`、`CLAUDE.md`
