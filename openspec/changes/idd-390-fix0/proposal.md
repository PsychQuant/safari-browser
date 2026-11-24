## Why

`idd-390-save-pdf-service-worker-pdf` 讓受 service worker 控制的 PDF 分頁照常讀、讀完再判定，前提是「PDF 文件讀自己的網址時，service worker 不經手」。封存後補量了一格（#390 comment 7142919264）：WebKit 沒持有那份文件時（被丟掉，或網址被改過），這次讀取照一般的 fetch 交給 service worker，service worker 可以向網路送出請求，沒帶旗標也一樣，而且發生在判定之前。結果仍是不存檔，但幾則失敗訊息與規格的一條 scenario 仍寫「沒有送出請求」，在受控分頁上不再一定成立。另外，判定遇到 `workerStart` 不是數字的 entry 時提前回 `unconfirmed`，會蓋掉同一批裡 `workerStart` 大於 0 的 entry，帶旗標時輸出的判定不準。

## What Changes

- `notHeld`、`badStatus`、`readFailed`、`bytesNotPDF` 四則失敗訊息：「沒有送出請求」改成「除非 service worker 控制這個分頁」的寫法，說明那時讀取交給了 service worker，它可以向網路回答。
- 規格 `save-pdf`：「bytes WebKit does not hold are not fetched」限定在沒有 service worker 控制的分頁；新增受控分頁沒持有文件的 scenario 與 Example；判定的優先順序改成有 `workerStart` 大於 0 的 entry 時一律是 `seen`。
- 規格 `non-interference`：寫明 WebKit 沒持有文件時，受控分頁的讀取會到 service worker，沒帶旗標也一樣。
- 頁內腳本的 `verdict()`：先看有沒有 `workerStart` 大於 0 的 entry，再看有沒有無法判讀的 entry。
- 文件：README、CLAUDE.md、CHANGELOG 的說明改成實話。

## Non-Goals

- 不改成「沒帶旗標時不讀受控分頁」。那是 #390 comment 7142919264 留給維護者的決定；這個 change 只修正不成立的敘述與判定的優先順序。
- 不偵測 WebKit 是否還持有文件：頁面沒有不經過 service worker 的方法可以事先知道。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `save-pdf`: 「save-pdf saves the displayed PDF without any request」限定 scenario、新增受控分頁沒持有文件的 scenario；「Only a PDF document is read, and a service worker's part is checked」改判定的優先順序。
- `non-interference`: 「save-pdf is non-interfering and sends no request」寫明受控分頁沒持有文件時的情形。

## Impact

- Affected specs: `save-pdf`、`non-interference`
- Affected code:
  - Modified: `Sources/SafariBrowser/Utilities/TabPDFReader.swift`、`Sources/SafariBrowser/Utilities/SavePDFFailure.swift`、`Tests/SafariBrowserTests/TabPDFReaderTests.swift`、`Tests/SafariBrowserTests/TabPDFWebKitTests.swift`、`README.md`、`CLAUDE.md`、`CHANGELOG.md`
  - New: (none)
  - Removed: (none)
