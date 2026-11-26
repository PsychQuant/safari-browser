## Why

`idd-390-save-pdf-service-worker-pdf` 與 `idd-390-fix0` 讓受 service worker 控制的 PDF 分頁照常讀、讀完再以 `workerStart` 判定，沒帶 `--allow-service-worker` 時只留判定是 not-seen 的讀取。#390 comment 7142919264 量到：WebKit 沒持有那份文件時（被丟掉，或頁面改了網址），這次讀取在判定之前就交給 service worker，網路型的 service worker 會向網站送出請求，沒帶旗標也一樣。維護者 2026-11-27 決定（comment 7201248012）：受控分頁沒帶旗標時，在讀之前就拒絕；帶了旗標才讀。verify 第 1 輪（comment 7144374735）另有幾項仍成立的 In-scope fix，一併處理。

## What Changes

- 頁內腳本：分頁受控而沒帶旗標時，在 `fetch` 之前以 `service-worker` 結束，不呼叫 `performance`；帶了旗標，網址在讀之前取一次，fetch 與判定共用；判定之後每一種都保留位元組。
- `SavePDFFailure`：`.serviceWorker` 回來，訊息開頭仍是「A service worker controls this tab」，說明沒有讀、沒有送出請求，並指向旗標；拿掉 `.serviceWorkerSaw` 與 `.serviceWorkerUnconfirmed`。`notHeld`、`badStatus`、`readFailed`、`bytesNotPDF` 的例外改成「帶了旗標、而且 service worker 控制這個分頁」。
- 狀態的封閉格式：`fail:service-worker:` 是 service-worker 錯誤，`fail:sw-seen:`、`fail:sw-unconfirmed:` 是損壞的回覆。沒帶旗標的呼叫收到判定不是 `none` 的成功回覆，在讀回位元組之前算損壞的回覆。
- `SavePDFCommand`：旗標說明、abstract（也是 MCP 工具描述）與 discussion 照新行為寫。
- 規格：兩個 requirement 改名（`without a request of its own`、`sends no request of its own`），受控分頁的 scenario 與 Example 照新行為重寫，每個 WHEN 寫明旗標狀態。
- 測試：替身頁面、指令層、真 WebKit（以哨兵 fetch 確認拒絕時 service worker 沒有收到讀取）。
- e2e：沒帶旗標的拒絕、帶旗標的 not-seen、帶旗標 `replaceState` 後的 seen；新視窗的 profile 不符就中止；清理重試不會對到兩個分頁。
- 文件：README、CLAUDE.md、CHANGELOG。

## Non-Goals

- 不偵測 WebKit 是否還持有文件：頁面沒有不經過 service worker 的方法可以事先知道。
- 不決定 MCP 的 `safari.save-pdf` 要不要曝露 `allow-service-worker`：這一輪照現狀讓它出現，並在 CHANGELOG 記下，等維護者回答。
- 不改不受控分頁的讀法與輸出。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `save-pdf`: 「save-pdf saves the displayed PDF without any request」改名為「save-pdf saves the displayed PDF without a request of its own」並改寫；「Only a PDF document is read, and a service worker's part is checked」改成沒帶旗標時事前拒絕；「The transfer belongs to one call and one document」的狀態格式。
- `non-interference`: 「save-pdf is non-interfering and sends no request」改名為「save-pdf is non-interfering and sends no request of its own」並改寫。

## Impact

- Affected specs: `save-pdf`、`non-interference`
- Affected code:
  - Modified: `Sources/SafariBrowser/Utilities/TabPDFReader.swift`、`Sources/SafariBrowser/Utilities/SavePDFFailure.swift`、`Sources/SafariBrowser/Commands/SavePDFCommand.swift`、`Tests/SafariBrowserTests/TabPDFReaderTests.swift`、`Tests/SafariBrowserTests/TabPDFWebKitTests.swift`、`Tests/e2e-save-pdf.sh`、`README.md`、`CLAUDE.md`、`CHANGELOG.md`
  - New: (none)
  - Removed: (none)
