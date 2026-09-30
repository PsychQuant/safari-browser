## Why

#210：出版商網站會把「頁面上多送一次請求」判成機器人（#183 的分頁內 `fetch()` 是那一種）。Safari 顯示 PDF 時不必再送任何請求：WebKit 的網路快取已把回應本體原樣存在磁碟上。這條路徑只讀檔案，不碰網站，也不需要人按任何按鈕。

2026-09-30 的決定：做成獨立指令（不併進 #183）；一律要求明確指定要哪一份，否則拒絕；對應不到或對應到多份時停止並列出候選，不猜、不改走別條路。

本機唯讀探查（只讀結構）：`WebKitCache/Version 17/Records/<partition>/Resource/<key>-blob` 是回應本體，檔頭 `%PDF-` 的只有 2 份；同名 record（無 `-blob`）的開頭依序是 `uint32 版本(17)`、`string 分區`、`string "Resource"`、`string 識別字（＝請求 URL）`，其中 string 為 `uint32 長度 + 1 byte is8Bit + 字元`，沒有對齊填充。

## What Changes

- 新增 `safari-browser pdf-cache`，兩個子指令：
  - `pdf-cache list`：列出快取中的 PDF（key 前綴、分區、去掉 query 與 fragment 的網址、大小、時間）。預設上限 50 筆、`--json`；`--source webkit-pdfs` 改列 `WebKitPDFs-*` 內的 PDF。
  - `pdf-cache get <path>`：依明確指定取出一份，指定形式只有三種（封閉列舉）：分頁定位旗標、`--key`、`--source webkit-pdfs --file`。沒有指定就拒絕。分頁定位以該分頁網址（去 fragment）與 record 的請求 URL **精確比對**；0 份或多份都停止並列出候選。
- 取出的副本：先驗檔頭 `%PDF-`，寫入目的地資料夾的暫存檔（mode `0600`），以 CoreGraphics 驗證可讀且至少一頁，再以 rename 原子發佈；目的地已存在則拒絕，除非 `--force`。任何一步失敗都不留下目的檔與暫存檔。
- 快取版本與 record 格式是 WebKit 私有格式：只支援已驗證的版本目錄；record 前四個欄位不符就明確失敗（fail closed），並說明看到了什麼。
- `non-interference`：新增兩個子指令的分級（Non-interfering）與資料敏感度記載。

## Capabilities

### New Capabilities

- `pdf-cache`：從 Safari 的 WebKit 網路快取取出已載入的 PDF，不送任何請求。

### Modified Capabilities

- `non-interference`：新增快取 PDF 指令的分級。

## Impact

- 新檔案：`Utilities/WebKitCacheReader.swift`、`Utilities/PDFCacheSelection.swift`、`Utilities/PDFCacheOutput.swift`、`Commands/PDFCacheCommand.swift` 與對應測試（合成 fixture，不讀使用者的真實快取）。
- `SafariBrowser.swift` 註冊一行、`Errors.swift` 新增錯誤、`TargetOptions` 加一個 `hasExplicitTarget`。
- 文件：CLAUDE.md、docs、CHANGELOG；plugin repo 的 SKILL.md 為跨 repo 同步（不在本 PR）。
- 不做：對真實站台或使用者 Safari session 的 live 實驗；快取的淘汰規則與私密瀏覽是否寫快取（未驗證，指令不承諾）；本體內嵌在 record 內（沒有 `-blob` 旁檔）的小回應（未驗證其門檻，列為殘留）。
