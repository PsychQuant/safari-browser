## 1. 測試先行（RED）

- [x] 1.1 [P] 在 `Tests/SafariBrowserTests/TabPDFReaderTests.swift` 以替身頁面寫判定優先順序的測試，帶標記 `spec-example: save-pdf / an entry above 0 outweighs one without a number`（表中三列：`NaN` 與 12 帶旗標存檔且判定 `seen`、`NaN` 與 0 帶旗標判定 `unconfirmed`、`NaN` 與 12 不帶旗標以 `fail:sw-seen:` 結束），並在 `SavePDFFailureTests` 斷言 `notHeld`、`badStatus`、`readFailed`、`bytesNotPDF` 四則訊息都寫明「unless a service worker controls this tab」。對應 requirement「Only a PDF document is read, and a service worker's part is checked」與「save-pdf saves the displayed PDF without any request」。驗證：`PATH=/usr/bin:$PATH swift test --filter 'TabPDFReaderScriptTests|SavePDFFailureTests'` 在實作前有斷言失敗。
- [x] 1.2 [P] 把 `Tests/SafariBrowserTests/TabPDFWebKitTests.swift` 的暫時量測測試改成正式測試 `testAControlledTabWhoseDocumentIsNotHeldReachesTheServiceWorker`，帶兩個標記 `spec-example: save-pdf / a controlled PDF tab whose address was never loaded` 與 `spec-example: non-interference / a controlled PDF tab whose document is not held`：`replaceState` 到從沒載入過的網址後讀取，伺服器紀錄多了 service worker 的記號與那個網址的請求，失敗是 `badStatus(code: 404)`，訊息含「unless a service worker controls this tab」。對應 requirement「save-pdf is non-interfering and sends no request」。驗證：`PATH=/usr/bin:$PATH make test-save-pdf-webkit` 在訊息改之前失敗。

- [x] 1.3 [P] 在 `Tests/SafariBrowserTests/TabPDFWebKitTests.swift` 加回歸測試 `testAControlledTabWhoseDocumentIsNotHeldAndIsAnsweredIsSeen`，帶標記 `spec-example: save-pdf / a controlled PDF tab whose document is not held and the service worker answers it`：`replaceState` 到 `doc.pdf?v=2` 後，沒帶旗標得到 `serviceWorkerSaw`、伺服器收到那個網址的請求，帶旗標存下伺服器送的 PDF 且判定 `seen`。這是釘住既有行為的測試（spectra-verify 第 4 個 warning：這一格沒有測試）。驗證：`SAVE_PDF_WEBKIT=1 PATH=/usr/bin:$PATH swift test --filter testAControlledTabWhoseDocumentIsNotHeldAndIsAnsweredIsSeen` 綠燈。

## 2. 實作（GREEN）

- [x] 2.1 改 `TabPDFReader.startScript` 的 `verdict()`：先找有沒有 `workerStart` 大於 0 的 entry（有就是 `seen`），其次有無法判讀的 entry 就是 `unconfirmed`，再來才是 `not-seen`；不再提前回傳。驗證：1.1 的優先順序測試與既有的 `testAnEntryWithoutANumericWorkerStartIsUnconfirmed` 綠燈。
- [x] 2.2 改 `SavePDFFailure` 的 `notHeld`、`badStatus`、`readFailed`、`bytesNotPDF` 訊息，落實 requirement「save-pdf saves the displayed PDF without any request」新增的那一句：不再無條件說沒有送出請求，寫明 service worker 控制分頁時讀取交給了它、它可以向網路回答。驗證：1.1 的訊息測試與 `testEveryMessageSaysNothingWasRequestedWhereItMatters` 綠燈。
- [x] 2.3 讓 1.2 的 WebKit 測試與全套測試通過。驗證：`PATH=/usr/bin:$PATH make test-save-pdf-webkit` 16/16、`PATH=/usr/bin:$PATH make test` 0 失敗。

## 3. 文件

- [x] 3.1 更新 `README.md` 的 save-pdf 一節、`CLAUDE.md`〈Tab PDFs〉、`CHANGELOG.md`：WebKit 沒持有文件時，受控分頁的讀取會交給 service worker，沒帶旗標也一樣、而且在判定之前；存檔的保證不變。對應 requirement「save-pdf is non-interfering and sends no request」。驗證：內容審查，三處都不再寫「網站看不到預設的讀法」而不加條件。
- [x] 3.2 [P] 讓其餘說法與 requirement「save-pdf saves the displayed PDF without any request」新增的那一句一致：`SavePDFCommand` 的 abstract（也是 MCP 工具描述）、`--help` 說明與檔頭註解、`TabPDFReader` 檔頭註解、`PDFCacheFailure` 給 pdf-cache 的提示、README 的標題與失敗說明，都寫出 service worker 的例外；四則失敗訊息改成「可能交給了 service worker」；`unconfirmed` 的訊息與註解照實寫「沒有 entry 說得出來」。驗證：`git grep -n "without requesting it"` 在 `Sources` 與 `README.md` 沒有不加條件的命中，內容審查。
