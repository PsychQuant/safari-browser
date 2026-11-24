## Context

`save-pdf`（#338）在明確鎖定的分頁裡執行一段頁內腳本，以 `fetch(location.href, {cache: 'only-if-cached', mode: 'same-origin'})` 讀 WebKit 持有的 PDF，存成檔案。這是腳本裡唯一的網路 API，失敗就失敗，不換讀法。腳本目前在 fetch 之前檢查 `navigator.serviceWorker.controller`，有值就以 `service-worker` 結束，理由是 service worker 看得到它控制的頁面發出的每一個 fetch，可能改從網路回答。

2026-11-25 的量測（#390 的 Diagnosis 與 comment 7140945239）：

- Safari 27.3，本機測試頁，三種 service worker（`pass` 原樣轉送、`net` 每次向網路重抓、`noh` 沒有 fetch handler）。受控的 PDF 分頁上，同一個 `only-if-cached` 讀法回 200、250,406 bytes，sha256 與伺服器送出的相同；service worker 沒有收到 fetch 事件（它每收到一個就向伺服器打一個 `/sw-saw` 記號），伺服器沒有收到請求。
- AppleScript `save` 文件 20 秒後 AppleEvent 逾時（-1712），沒有寫出檔案：不可行。
- 正控制（畫面外 WKWebView，同一組測試頁）：service worker 經手的 fetch，resource entry 的 `workerStart` 是 1607、2114、6、509，`transferSize` 大於 0；PDF 文件讀**自己的網址**（`only-if-cached`、預設、`no-store` 三種）都沒有經手，`workerStart` 0、`transferSize` 0。entry 在 `blob()` resolve 之後立刻查得到，500 ms 後相同。受控的 HTML 頁上，`only-if-cached` 的 fetch 照樣交給 service worker。

維護者的決定：放在 `save-pdf` 裡；先用網站看不到的讀法，看得到的要旗標、預設關（comment 7139964376）；沒帶旗標時照常讀，讀完以這次讀取的 `workerStart` 確認，0 才存，大於 0 或找不到紀錄就丟掉、指向旗標（comment 7140645678）。

## Goals / Non-Goals

**Goals:**

- 受 service worker 控制的 PDF 分頁存得下來，只要這次讀取沒有經過 service worker。
- 讀完的判定可以從輸出看到：不受控、受控但沒經手、經手了、無法確認。
- 經手或無法確認時，沒帶旗標就不存，訊息說明原因並指向 `--allow-service-worker`。
- 不受控的分頁行為完全不變：腳本不讀 resource timing。

**Non-Goals:**

- 不換讀法：旗標不改 cache mode、不加第二個 fetch、不走對話框或 AppleScript `save`（量過，不可行）。
- 不處理 PDF 嵌在 HTML 頁裡的情形（照舊以 not-a-PDF 結束）。
- 不修其他編譯 warning（#393）、`open --new-window` 不照 `--profile` 的問題（#383）、取全文的 skill（PsychQuant/Akashic-Library#836）。
- 不在事前預測 service worker 會不會經手：頁面沒有辦法事先知道。

## Decisions

### 讀完再判定，不在事前拒絕

事前拒絕的前提（service worker 會看到這次讀取）在 Safari 27.3 上對 PDF 文件讀自己的網址不成立，量過三種 service worker。可以在讀之前判斷的只有「分頁受不受控」，判斷不了「這次讀取會不會經手」，所以判定放在讀完之後。

考慮過的另一個做法：沒帶旗標時受控就不讀，只有帶旗標才讀。這樣最嚴，但量到看不到的讀法就不會是預設，與 comment 7139964376 的原則（先用看不到的讀法）相反；維護者在 7140645678 選了讀完再確認。

### 以這次讀取的 resource entry 判定，取最大的 `workerStart`

fetch 之前記下 `controlled = !!(navigator.serviceWorker && navigator.serviceWorker.controller)`。不受控時完全不呼叫 `performance`，讓這條路徑與現在逐字相同；受控時在 fetch 之前取 `t0 = performance.now()`，`blob()` resolve 之後讀 `performance.getEntriesByType('resource')`，留下三個條件都成立的 entry：`name` 去掉 fragment 後等於 `location.href` 去掉 fragment、`initiatorType === 'fetch'`、`startTime >= t0`。判定：

| 條件 | 判定 |
|---|---|
| 不受控 | `none`（不讀 resource timing） |
| 受控，`performance.now` 或 `getEntriesByType` 不是函式或丟出例外，或沒有符合的 entry | `unconfirmed` |
| 受控，符合的 entry 中最大的 `workerStart` 大於 0 | `seen` |
| 受控，符合的 entry 全部 `workerStart` 是 0 | `not-seen` |

有多筆符合時取最大值：頁面自己在同一刻 fetch 同一個網址時，可能多擋一次，不會多存一次。名稱去掉 fragment 再比，因為 PDF 分頁的網址常帶 `#page=2` 這類 fragment，而 fetch 的 entry 名稱不帶。

### 判定放在 `blob()` 之後、大小檢查與編碼之前

`seen` 或 `unconfirmed` 而沒帶旗標時，位元組不編碼，也不經 `do JavaScript` 傳回。50 MB 在 Safari 上傳一趟約 31 秒，被拒的檔不必付這個代價。判定排在 `too-large` 之前：不能存的時候，先說不能存的原因。

### 狀態與輸出共用一組封閉的值

成功的狀態從 `ok:<bytes>:<len>` 變成 `ok:<bytes>:<len>:<sw>`，`<sw>` 只能是 `none`、`not-seen`、`seen`、`unconfirmed`，其他值與舊的兩欄形式一律是 damaged reply。失敗新增 `fail:sw-seen:` 與 `fail:sw-unconfirmed:`（detail 是空的）。`--json` 一律帶 `service_worker`，值是那四個之一；文字輸出在 `none` 時與現在逐字相同，其他三種在結尾加 `  service worker: <值>`。考慮過文字輸出一律加註：會讓每一次的輸出都變，對不受控的分頁沒有資訊。

### 旗標只決定要不要留下位元組

`--allow-service-worker` 以布林字面值傳進啟動腳本（腳本照舊不含網址）。帶了旗標，`seen` 與 `unconfirmed` 的位元組也留下，判定照實寫在輸出。旗標不碰 fetch 的參數。

## Implementation Contract

**行為**

- 分頁不受控：與現在相同，唯一的差別是 `--json` 多 `"service_worker": "none"`。
- 分頁受控、判定 `not-seen`：存檔，exit 0；文字列結尾 `  service worker: not-seen`，JSON `"service_worker": "not-seen"`。
- 分頁受控、判定 `seen` 或 `unconfirmed`、沒帶旗標：exit 1，目的地沒有檔案，暫存資料夾不存在，位元組沒有傳回 CLI。
- 同上、帶 `--allow-service-worker`：存檔，exit 0，輸出寫出判定。

**介面與資料形狀**

- `safari-browser save-pdf <path> [--allow-service-worker] [--force] [--json] <target>`。
- 頁內狀態：`gone` | `wait` | `ok:<bytes>:<len>:<sw>` | `fail:<code>:<detail>`；`<code>` 增加 `sw-seen`、`sw-unconfirmed`，移除 `service-worker`。
- `TabPDFReader.Read` 多一個判定欄位；`TabPDFReader.Status.ok` 帶判定；`TabPDFReader.startScript` 多一個參數表示旗標。
- `SavePDFFailure`：移除 `.serviceWorker`，新增 `.serviceWorkerSaw` 與 `.serviceWorkerUnconfirmed`。
- `PDFCacheFormat.tabSavedRow`／`tabSavedJSON` 收判定。

**失敗訊息**

- `.serviceWorkerSaw`：說明位元組讀到了但沒有存，因為 service worker 經手了這次讀取（它可能已向網路送出請求），要存就加 `--allow-service-worker`。
- `.serviceWorkerUnconfirmed`：說明位元組讀到了但沒有存，因為確認不了 service worker 有沒有經手（找不到這次讀取的紀錄），要存就加 `--allow-service-worker`。
- 兩則都不寫「沒有送出請求」。

**驗收**

- `TabPDFReaderTests`（替身頁面）：每一種判定、旗標兩種值、四種狀態形式的解析、未知判定是 damaged、不受控的腳本路徑不讀 resource timing、兩則訊息的內容。
- `TabPDFWebKitTests`（`make test-save-pdf-webkit`，真的 WebKit）：受控 PDF 分頁判定 `not-seen`、位元組與伺服器送出的相同、讀取期間沒有新請求、service worker 沒有留下記號；以 `performance.setResourceTimingBufferSize(0)` 讓紀錄找不到時，沒帶旗標失敗、帶旗標存檔。WebKit 若不照這個 API 丟掉紀錄，改用替身並在規格寫明。`seen` 在真的 WebKit 上做不出來（PDF 文件讀自己的網址不經手），只用替身測。
- `Tests/e2e-save-pdf.sh`（Safari，會開前景視窗）：加 `pass`、`net` 兩個 service worker scope。這一步要人在旁邊跑（#383），列為待人驗收的 task。
- `make test` 全部通過。

**範圍**

- 範圍內：`TabPDFReader`、`SavePDFFailure`、`SavePDFCommand`、`PDFCacheFormat` 的 save-pdf 部分、上述三層測試、CLAUDE.md〈Tab PDFs〉、README 的 save-pdf 一節、CHANGELOG、兩份規格。
- 範圍外：`pdf-cache`（它不執行 JavaScript，不受影響）、MCP（沒有 save-pdf 工具）、其他指令。

## Risks / Trade-offs

- [將來的 Safari 讓 service worker 經手這次讀取] → 那一次 service worker 已經看到了，只是不存（沒帶旗標時）。維護者在 comment 7140645678 接受這個代價。WebKit 層的測試釘住現在的行為，換新版 Safari 時重跑 e2e。
- [`workerStart` 是頁面世界裡的資料，頁面腳本改得到] → 威脅模型是失誤，不是惡意頁面（CLAUDE.md〈Tab PDFs〉最後一點）；顯示 PDF 的文件沒有頁面腳本。
- [resource timing 緩衝區滿了] → 找不到紀錄，判定 `unconfirmed`，沒帶旗標時不存。偏向拒絕。
- [頁面自己同時 fetch 同一個網址] → 多一筆符合的 entry，取最大值，可能多擋一次。
- [`--json` 多一個鍵] → 讀取端多半忽略未知的鍵；文字列只在受控時改變。

## Migration Plan

規格的改名用 `FROM: ### Requirement: …`／`TO: ### Requirement: …` 兩行（不加清單符號與反引號），MODIFIED 用新名稱：這個 Spectra 版本對加了清單符號或反引號的寫法照樣回 valid，但封存時不改名。2026-11-25 在副本上實際封存過：`spectra archive --preview` 回 save-pdf modified 4、renamed 1，封存後的標題是新名稱。`spectra analyze` 仍報 GAP-1（拿新名稱到主規格找不到），那是 analyzer 不處理改名造成的，不是缺漏。

不需要遷移。CHANGELOG 寫明受控分頁從「一律失敗」變成「讀完判定」，以及新的旗標與 JSON 鍵。退回的方法是 revert 這個 change 的 commit。
