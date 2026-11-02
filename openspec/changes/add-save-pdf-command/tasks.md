## 1. 頁面腳本與狀態解析

- [x] 1.1 `TabPDFReader.startScript` 在 `FakePage`（JavaScriptCore，附 `document`／`navigator`／`fetch`／`FileReader` shim）真的執行：PDF 文件把 base64 存進這次呼叫的槽，`fetch` 只被呼叫一次且選項為 `cache:'only-if-cached'`、`mode:'same-origin'`。驗證：`swift test --filter TabPDFReaderScriptTests`（requirement: save-pdf saves the displayed PDF without any request；design: 一律 `cache: 'only-if-cached'`，沒有第二條路）
- [x] 1.2 非 PDF 文件與受 service worker 控制的頁面回報對應失敗，且 shim 記錄 `fetch` 沒被呼叫；`status` 非 2xx、rejected、超過 `maxBytes` 各回報 `status`／`not-held`／`too-large`，超過上限時沒有呼叫 `FileReader`。驗證：同上（requirement: Only a PDF document outside a service worker is read；design: 大小上限 256 MiB）
- [x] 1.3 結構檢查：`startScript` 的文字只含一個 `fetch(`，不含 `XMLHttpRequest`、`sendBeacon`、`WebSocket`、`EventSource`、`importScripts`、`force-cache`、`reload`。驗證：`swift test --filter TabPDFReaderScriptTests`
- [x] 1.4 `parseStatus` 只接受 `gone`、`wait`、`ok:<bytes>:<len>`、`fail:<code>:<detail>`（已知 code），其他一律 `.damaged`。驗證：`swift test --filter TabPDFReaderStatusTests`

## 2. 失敗類型

- [x] [P] 2.1 `SavePDFFailure` 的十三個 case 接到 `SafariBrowserError`，每個訊息說明原因與下一步，`notHeld` 寫明「沒有送出任何請求」，結束碼 1；訊息不含測試埋的 `SECRET`。驗證：`swift test --filter SavePDFFailureTests`（design: 錯誤是封閉列舉 `SavePDFFailure`）

## 3. 讀取流程

- [x] 3.1 `TabPDFReader.read` 接 `FakePage`：輪詢到完成、分塊讀回、byte 數相符才回傳、結束移除槽；52 MB 以下的內容逐位元組相同。驗證：`swift test --filter TabPDFReaderFlowTests`
- [x] 3.2 讀取途中換頁（`FakePage.replaceDocument()`，於任兩個往返之間）一律失敗；超過期限回 `timedOut` 且不嘗試移除槽；byte 數不符回 `damagedReply`；兩個同時的呼叫各自完整。驗證：`swift test --filter TabPDFReaderFlowTests`（requirement: The transfer belongs to one call and one document）

## 4. 發布

- [x] 4.1 `PDFCacheOutput.refuseExistingDestination` 在讀取前擋下既有目的地（無 `--force`），`--force` 時放行；`copyVerified` 既有測試不變。驗證：`swift test --filter SavePDFPublishTests`
- [x] 4.2 解碼後寫入 `mkdtemp` 私有資料夾（0700／0600）再交 `copyVerified`，成功與每一種失敗後暫存資料夾都不在；非 `%PDF-` 位元組失敗且目的地沒有檔。驗證：`swift test --filter SavePDFPublishTests`（requirement: The file is published through the verified path）

## 5. 指令

- [x] 5.1 `save-pdf` 註冊進 root；沒有目標或只有 `--first-match` 時回 64 且 AppleScript runner 沒被呼叫；`--profile` 被接受並加入 `honoredProfileCommandsHelp`。驗證：`swift test --filter SavePDFCommandTests`（requirement: The target tab must be named explicitly；design: 目標只解析一次）
- [x] 5.2 成功時印一行或 `--json`（`path`、`size`、`pages`、`source`、`url`），網址不含 query。驗證：`swift test --filter SavePDFCommandTests`（requirement: Output shows the URL without its secrets）
- [x] 5.3 MCP 工具清單包含 `save-pdf`，`Tests/mcp-stdio.py` 的工具數與實際相符（#306 既有的落差一併對齊）。驗證：`make test-mcp`

## 6. pdf-cache 指引

- [x] [P] 6.1 `pdf-cache get` 以分頁比對不到時訊息多一行指向 `save-pdf`；`PDFCacheTests` 的結構檢查仍通過（實作檔沒有腳本 API）。驗證：`swift test --filter 'PDFCacheNamesSavePDFTests|PDFCacheTests'`（requirement: pdf-cache names save-pdf when a tab has no cached copy）

## 7. 文件

- [x] [P] 7.1 README 新增 `save-pdf` 用法與限制，CLAUDE.md 記下設計理由（`only-if-cached`、service worker、為何不放進 pdf-cache），CHANGELOG 記錄使用者可見的行為。驗證：人工核對各旗標與 `save-pdf --help` 一致

## 8. 真機驗收

- [ ] 8.1 `Tests/e2e-save-pdf.sh`（`make test-save-pdf`）：沒有 `E2E_SAVE_PDF_OK=1` 就不碰 Safari；閘門是這個明確的同意，由人在適當時段、把要用的 profile 的視窗拉到前面後設定（機器上平常就有別的視窗，所以不以「有其他視窗」為停止條件）。以 localhost 伺服器提供 `no-store` PDF，在自己開的視窗驗證：先確認紀錄裡有顯示 PDF 的 GET，位元組相同、伺服器 0 個新請求、前景 app 不變、背景分頁可用且現用分頁不變、未持有網址失敗且 0 請求、讀不到 Safari 快取資料夾時仍可存（`sandbox-exec`）、50 MB 的耗時、支援 Range 的伺服器上要嘛完整要嘛拒絕。之後的步驟都以 fixture 網址或視窗 id 定址，只關自己的視窗。驗證：使用者同意的時段跑一次，結果寫進 PR（requirement: save-pdf is non-interfering and sends no request）
- [ ] 8.2 ScienceDirect 驗收：DOI 10.1016/j.wneu.2019.02.206 的分頁，`save-pdf` 存檔成功、`%PDF-`、頁數可讀。驗證：由持有該分頁的 session 執行並回報

## 9. Verify 第 1 輪的修正

- [x] 9.1 沒有 Full Disk Access 也能存：`copyVerified` 的 `protectedFoldersMayBeClosed`；pdf-cache 仍不放行打不開的資料夾。驗證：`swift test --filter SavePDFPublishTests`；`sandbox-exec` 拒絕讀快取資料夾後跑 `testTheDefaultProtectedFolderDoesNotStopAnOrdinaryDestination`（修正前失敗於 `PDFCacheOutput.swift:223`）（design: 不需要 Full Disk Access）
- [x] 9.2 腳本比對先讀到的網址，移位或重新解析都不會讀到別的文件。驗證：`swift test --filter TabPDFReader`（design: 先讀網址，腳本再比對）
- [x] 9.3 回應要 status 200、不是 redirect、是分頁這個網址；206 不算文件。驗證：同上（design: 回應要是這個網址的完整文件）
- [x] 9.4 只回報錯誤名稱；fetch 之後的失敗不報成 WebKit 沒持有；逗號與 scalar 的邊界。驗證：同上
- [x] 9.5 CLI 複核頁面報的數字；期限從啟動前算，逾時才回來的結果不收。驗證：同上
- [x] 9.6 分頁消失時指名目標、不列分頁；輸出網址經 `URLText.redactURL`；訊息不顯示暫存檔名；父路徑是檔案時提早拒絕。驗證：`swift test --filter SavePDF`
- [x] 9.7 重寫 e2e：同意之前不碰 Safari、以視窗 id 定址、「沒有請求」有正向對照、未持有案例、無 FDA 案例、Range 伺服器。驗證：`bash -n`，未設旗標時 exit 77；真機結果見 8.1
