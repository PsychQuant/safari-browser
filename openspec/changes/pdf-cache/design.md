## Context

WebKit 網路快取在 `~/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/WebKitCache/Version <N>/`。每筆 record 在 `Records/<分區雜湊>/Resource/<key>`，較大的回應本體在同資料夾的 `<key>-blob`（`Blobs/<SHA1>` 是同一份資料的另一條路徑，本設計不使用）。讀這個資料夾需要 Full Disk Access，且 FDA 綁在 code signature 上，與 `history`／`downloads` 相同。

## Decisions

1. **獨立指令，兩個子指令。** `list` 讓使用者（或另一個 skill）看見有什麼，`get` 取出一份。不做「取最新」：使用者在 2026-09-30 明確選了「一律要求明確指定，否則拒絕」。
2. **來源是快取，不是 `WebKitPDFs-*`。** 快取不需要人按任何按鈕、不送請求。`WebKitPDFs-*` 只有在使用者按「用預覽程式打開」之後才存在，所以只作為使用者明示（`--source webkit-pdfs`）的次要來源，CLI 不代按。
3. **record 只解析 key 區段。** 版本、分區、type、識別字（＝請求 URL）、range（`0xFFFFFFFF` 表示沒有）、20 位元組 hash 依序在固定位置，不需掃描；hash 必須等於 record 的檔名，這讓「解析錯位」變成看得見的錯誤（版式一改，讀到的 20 位元組就不再是檔名，該 record 被拒絕而不是被信任）。以真實快取上全部 9221 筆 record 驗證過（8-bit 識別字 8572、16-bit 649、非空分區 658、range 一律為 null、hash 一律等於檔名）。response 區段（含 mime、標頭）的編碼複雜且未驗證，不解析。是不是 PDF 由 `<key>-blob` 的前 5 個位元組（`%PDF-`）決定；`-blob` 必須是一般檔案（資料夾與 symlink 略過）；帶 range 的 record 存的是資源的一段，不列出、不可選取。
4. **掃描成本。** 快取有數千個 record；對每個 `-blob` 只讀 5 個位元組，命中者才讀 record。
5. **對應是精確字串相等。** 分頁網址去掉 fragment 後與識別字比對，不做正規化（不補斜線、不排序 query）。對應不到時不猜，列出去掉 query 的候選，要求 `--key`。多個分區各存一份同一網址的情況一樣停止。
6. **URL 一律去掉 query 與 fragment 再顯示**（列表、JSON、錯誤訊息），因為簽章網址的 query 可能是憑證。比對用完整字串，顯示用去掉的版本。
7. **`--key` 是 record 檔名（40 個十六進位字元）的唯一前綴，至少 8 個字元。** 不唯一就停止。
8. **輸出：** 目的地資料夾內建 `O_EXCL` 暫存檔（`0600`），串流複製，驗證後 `renamex_np(RENAME_EXCL)`（`--force` 時 `rename`）。來源以唯讀開啟，不修改。驗證用 `CGPDFDocument`（`numberOfPages > 0`），不新增 framework。
9. **版本目錄：** 只接受 `Version 17`。看到其他版本時明確失敗並列出看到的目錄名，不猜測相容。
10. **錯誤處理：** 權限錯誤走既有 `SafariDataStore.ioError`（保留 errno、依簽章狀態給 FDA 指引）。快取資料夾不存在視為錯誤（Safari 一定有這個資料夾），不像 `CloudTabs.db` 那樣是正常狀態。

## Risks / Trade-offs

- 快取格式是 WebKit 私有格式，版本升級後會失效 → fail closed 並說明。
- 這個快取含所有站台的資源 → 只讀 PDF 命中者的 record，`list` 只列 PDF，預設上限 50。
- 回應本體內嵌在 record 內的小回應沒有 `-blob` → 不在範圍內，找不到時訊息提到這一點。
