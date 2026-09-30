## 1. 快取讀取

- [ ] 1.1 測試先失敗：record 前四個欄位解析（8-bit 與 16-bit 字元、空分區、非空分區）、截斷／長度超限／type 不是 Resource／版本不符一律失敗（Requirement: The cache layout is validated and unsupported layouts fail closed）
- [ ] 1.2 實作 `WebKitCacheReader`：版本目錄（只接受 Version 17）、列舉分區、以 `-blob` 前 5 位元組篩 PDF、解析 record
- [ ] 1.3 測試：沒有 Version 目錄、只有不支援的版本、PDF blob 存在但全部無法解析（版式漂移）
- [ ] 1.4 權限與 I/O 錯誤保留 errno：`EACCES`／`EPERM` 走 Full Disk Access 指引，其他錯誤不被說成權限問題或找不到（Requirement: Access failures keep their cause）

## 2. 選取與取出

- [ ] 2.1 測試先失敗：沒有指定就拒絕且零副作用、多種指定形式互斥、`--profile` 或 `--first-match` 單獨不算指定（Requirement: Retrieval requires an explicit selection）
- [ ] 2.2 測試先失敗：精確 URL 比對（去 fragment、query 有差就不相符）、0 份與多份都拒絕並列候選、`--key` 唯一前綴且至少 8 字元（Requirement: A tab selection maps to a record by exact URL）
- [ ] 2.3 實作 `PDFCacheSelection`（純函式）與 `TargetOptions.hasExplicitTarget`
- [ ] 2.4 測試先失敗：寫出（`%PDF-` 驗證、可讀且至少一頁、`0600`、已存在拒絕、`--force`、失敗不留目的檔與暫存檔、來源不被修改）（Requirement: Retrieval writes a verified copy atomically）
- [ ] 2.5 實作 `PDFCacheOutput`

## 3. 指令

- [ ] 3.1 測試先失敗：`list`（只列 PDF、預設上限 50、新到舊、text 與 JSON、去 query 與 fragment、stdout／stderr 分工、無 PDF 時空輸出加說明）（Requirements: The listing shows PDFs only, URLs are shown without query or fragment）
- [ ] 3.2 實作 `PDFCacheCommand`（list／get）、`Errors.swift`、註冊
- [ ] 3.3 `--source webkit-pdfs` 的列舉與 `--file` 取出；CLI 不觸發該資料夾的建立（Requirement: The WebKitPDFs source is opt-in）
- [ ] 3.4 測試：指令路徑上沒有網路呼叫、沒有對分頁執行 script、沒有觸發任何 Safari 控制項（結構性測試：指令原始碼不引用 URLSession／doJavaScript／AXPress）（Requirement: The command reads only the WebKit network cache and sends no request）
- [ ] 3.5 `non-interference` 分級與敏感度（Requirement: Cached-PDF commands are non-interfering and send no request）

## 4. 文件與驗證

- [ ] 4.1 CLAUDE.md、docs、CHANGELOG
- [ ] 4.2 `spectra validate`、全套單元測試
