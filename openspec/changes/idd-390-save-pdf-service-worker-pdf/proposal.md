## Why

`save-pdf` 遇到受 service worker 控制的 PDF 分頁，在 fetch 之前就拒絕，理由是 service worker 看得到這次讀取、可能改從網路回答（#390）。2026-11-25 在本機測試頁上量到（Safari 27.3，三種 service worker），這個前提對 `save-pdf` 的讀法不成立：PDF 文件以 `only-if-cached` 讀自己的網址時，service worker 沒有收到 fetch 事件，伺服器沒有收到請求，存下的位元組與送出的相同。另以畫面外的 WKWebView 做了正控制：service worker 經手的 fetch，resource timing 的 `workerStart` 大於 0；沒經手的是 0。所以事前一律拒絕是多擋了；而「service worker 沒看到」可以在讀完之後確認。取全文的流程（PsychQuant/Akashic-Library#836）在 PeerJ 這類分頁上因此存不了檔。

## What Changes

- `save-pdf` 不再在 fetch 之前拒絕受控的分頁：照常讀，讀完以這次讀取的 resource timing 判定 service worker 有沒有經手，判定分四種：`none`（分頁不受控）、`not-seen`、`seen`、`unconfirmed`（找不到這次讀取的紀錄）。
- 沒帶新旗標時只存 `none` 與 `not-seen`；`seen` 與 `unconfirmed` 丟掉讀到的位元組、不編碼也不傳回，以兩個新的失敗結束，訊息指向旗標。
- 新增 `--allow-service-worker`（預設關）：帶了就連 `seen` 與 `unconfirmed` 也存下來。旗標不改讀法：仍是那一個 `only-if-cached` 的 fetch。
- 頁內腳本回報的狀態格式加一欄判定（`ok:<bytes>:<len>:<sw>`）；`--json` 的輸出加 `service_worker`；文字輸出只在分頁受控時加註判定。
- **BREAKING**：受控的分頁原本一律以 exit 1 失敗，現在多數情況下會存檔。依賴「受控就失敗」的呼叫端（目前沒有已知的）行為會改變。
- 原本的 `SavePDFFailure.serviceWorker` 拿掉，換成兩個新 case。
- 不受控的分頁：腳本不讀 resource timing，行為與現在相同，只多了輸出裡的 `service_worker: none`（JSON）。

## Non-Goals

見 design.md 的 Goals / Non-Goals。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `save-pdf`: 「Only a PDF document outside a service worker is read」改名並改寫成讀完再判定；封閉的狀態格式多一欄；`--json` 多 `service_worker`。
- `non-interference`: 「save-pdf is non-interfering and sends no request」不再寫「受控的頁面一律拒絕」，改寫成受控的頁面照常讀、讀完判定，以及帶旗標時 service worker 經手的那次讀取可能已經送出請求。

## Impact

- Affected specs: `save-pdf`、`non-interference`
- Affected code:
  - Modified: `Sources/SafariBrowser/Utilities/TabPDFReader.swift`、`Sources/SafariBrowser/Utilities/SavePDFFailure.swift`、`Sources/SafariBrowser/Commands/SavePDFCommand.swift`、`Sources/SafariBrowser/Utilities/PDFCacheFormat.swift`、`Tests/SafariBrowserTests/TabPDFReaderTests.swift`、`Tests/SafariBrowserTests/TabPDFWebKitTests.swift`、`Tests/e2e-save-pdf.sh`、`CLAUDE.md`、`README.md`、`CHANGELOG.md`
  - New: (none)
  - Removed: (none)
- 呼叫端：取全文的 skill（PsychQuant/Akashic-Library#836）等這一張發布後再改。
