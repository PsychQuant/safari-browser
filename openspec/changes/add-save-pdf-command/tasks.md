## 1. 頁面腳本與狀態解析

- [ ] 1.1 `TabPDFReader.startScript` 在 `FakePage`（JavaScriptCore，附 `document`／`navigator`／`fetch`／`FileReader` shim）真的執行：PDF 文件把 base64 存進這次呼叫的槽，`fetch` 只被呼叫一次且選項為 `cache:'only-if-cached'`、`mode:'same-origin'`。驗證：`swift test --filter TabPDFReaderScriptTests`（requirement: save-pdf saves the displayed PDF without any request；design: 一律 `cache: 'only-if-cached'`，沒有第二條路）
- [ ] 1.2 非 PDF 文件與受 service worker 控制的頁面回報對應失敗，且 shim 記錄 `fetch` 沒被呼叫；`status` 非 2xx、rejected、超過 `maxBytes` 各回報 `status`／`not-held`／`too-large`，超過上限時沒有呼叫 `FileReader`。驗證：同上（requirement: Only a PDF document outside a service worker is read；design: 大小上限 256 MiB）
- [ ] 1.3 結構檢查：`startScript` 的文字只含一個 `fetch(`，不含 `XMLHttpRequest`、`sendBeacon`、`WebSocket`、`EventSource`、`importScripts`、`force-cache`、`reload`。驗證：`swift test --filter TabPDFReaderScriptTests`
- [ ] 1.4 `parseStatus` 只接受 `gone`、`wait`、`ok:<bytes>:<len>`、`fail:<code>:<detail>`（已知 code），其他一律 `.damaged`。驗證：`swift test --filter TabPDFReaderStatusTests`

## 2. 失敗類型

- [ ] [P] 2.1 `SavePDFFailure` 的九個 case 接到 `SafariBrowserError`，每個訊息說明原因與下一步，`notHeld` 寫明「沒有送出任何請求」，結束碼 1；網址經 `PDFCacheURL.redact`，訊息不含測試埋的 `SECRET`。驗證：`swift test --filter SavePDFFailureTests`（design: 錯誤是封閉列舉 `SavePDFFailure`）

## 3. 讀取流程

- [ ] 3.1 `TabPDFReader.read` 接 `FakePage`：輪詢到完成、分塊讀回、byte 數相符才回傳、結束移除槽；52 MB 以下的內容逐位元組相同。驗證：`swift test --filter TabPDFReaderFlowTests`
- [ ] 3.2 讀取途中換頁（`FakePage.replaceDocument()`，於任兩個往返之間）一律失敗；超過期限回 `timedOut` 且不嘗試移除槽；byte 數不符回 `damagedReply`；兩個同時的呼叫各自完整。驗證：`swift test --filter TabPDFReaderFlowTests`（requirement: The transfer belongs to one call and one document）

## 4. 發布

- [ ] 4.1 `PDFCacheOutput.refuseExistingDestination` 在讀取前擋下既有目的地（無 `--force`），`--force` 時放行；`copyVerified` 既有測試不變。驗證：`swift test --filter PDFCacheOutputTests`
- [ ] 4.2 解碼後寫入 `mkdtemp` 私有資料夾（0700／0600）再交 `copyVerified`，成功與每一種失敗後暫存資料夾都不在；非 `%PDF-` 位元組失敗且目的地沒有檔。驗證：`swift test --filter SavePDFPublishTests`（requirement: The file is published through the verified path）

## 5. 指令

- [ ] 5.1 `save-pdf` 註冊進 root；沒有目標或只有 `--first-match` 時回 64 且 AppleScript runner 沒被呼叫；`--profile` 被接受並加入 `honoredProfileCommandsHelp`。驗證：`swift test --filter SavePDFCommandTests`（requirement: The target tab must be named explicitly；design: 目標只解析一次）
- [ ] 5.2 成功時印一行或 `--json`（`path`、`size`、`pages`、`source`、`url`），網址不含 query。驗證：`swift test --filter SavePDFCommandTests`（requirement: Output shows the URL without its query）
- [ ] 5.3 MCP 工具清單包含 `save-pdf`，`Tests/mcp-stdio.py` 的工具數與實際相符（#306 既有的落差一併對齊）。驗證：`make test-mcp`

## 6. pdf-cache 指引

- [ ] [P] 6.1 `pdf-cache get` 以分頁比對不到時訊息多一行指向 `save-pdf`；`PDFCacheTests` 的結構檢查仍通過（實作檔沒有腳本 API）。驗證：`swift test --filter PDFCacheTests`（requirement: pdf-cache names save-pdf when a tab has no cached copy）

## 7. 文件

- [ ] [P] 7.1 README 新增 `save-pdf` 用法與限制，CLAUDE.md 記下設計理由（`only-if-cached`、service worker、為何不放進 pdf-cache），CHANGELOG 記錄使用者可見的行為。驗證：人工核對各旗標與 `save-pdf --help` 一致

## 8. 真機驗收

- [ ] 8.1 `Tests/e2e-save-pdf.sh`（`make test-save-pdf`）：先列出 Safari 視窗，有非 fixture 的視窗就停下不開分頁（需 `E2E_SAVE_PDF_OK=1`）；以 localhost 伺服器提供 `no-store` PDF，在自己開的獨立視窗驗證 SHA-256 相同、伺服器 0 個新請求、背景分頁可用、未持有網址失敗且 0 請求，並量 50 MB 的耗時。驗證：使用者同意的時段跑一次，結果寫進 PR（requirement: save-pdf is non-interfering and sends no request）
- [ ] 8.2 ScienceDirect 驗收：DOI 10.1016/j.wneu.2019.02.206 的分頁，`save-pdf` 存檔成功、`%PDF-`、頁數可讀。驗證：由持有該分頁的 session 執行並回報
