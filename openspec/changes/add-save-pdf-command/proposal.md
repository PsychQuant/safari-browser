## Why

`pdf-cache get` 只讀 WebKit 的磁碟網路快取，而 `Cache-Control: no-store` 的回應不會寫進那裡，所以分頁明明顯示著 PDF 卻存不下來（#338，ScienceDirect 的簽章網址）。量測發現 WebKit 在記憶體裡還持有顯示中的文件，在分頁內以 `fetch(location.href, {cache: 'only-if-cached'})` 可以不連網讀出；維護者選定這條路（issue comment 6568753206）。

## What Changes

- 新指令 `safari-browser save-pdf <path>`：把明確鎖定的分頁正在顯示的 PDF 存成檔，不發請求、不動鍵盤滑鼠。
- 必須明確鎖定分頁（`--url`、`--url-exact`、`--url-endswith`、`--url-regex`、`--window [--tab-in-window]`、`--document`、`--tab`），沒有預設的 front tab；接受 `--profile` 與 `--first-match`。
- 分頁文件不是 PDF、受 service worker 控制、WebKit 沒持有或頁面政策擋下、超過大小上限時失敗，一律不退回連網。
- 寫檔重用 `PDFCacheOutput.copyVerified`（`%PDF-`、頁面檢查、`--force`、只用打開的資料夾），輸出一行或 `--json`（`path`、`size`、`pages`、`source`、`url`，網址去掉 query 與 fragment）。
- `pdf-cache get` 以分頁比對不到時，錯誤訊息指向 `save-pdf`。

## Non-Goals

- 不改 `pdf-cache` 的行為與規格（它「不執行 JavaScript、不操作 Safari」的契約不變）；只有 no-match 訊息多一句指引。
- 不涵蓋嵌在 HTML 裡的 PDF（`<embed>`、`<iframe>`、PDF.js）：分頁文件不是 PDF。
- 不走 Safari 的「儲存為」或 PDF 檢視器的浮出按鈕（要 HID，維護者已排除）。
- 不改 `save-image`（它的 Referer 問題在 #336）。
- skill 文件（psychquant-claude-plugins）與 akashic-fetch-fulltext（Akashic-Library#766）在發布後另外更新。

## Capabilities

### New Capabilities

- `save-pdf`: 把分頁顯示中的 PDF 從 WebKit 已持有的位元組存成檔，不發請求。

### Modified Capabilities

- `non-interference`: 新增 `save-pdf` 的干擾分類（Non-interfering，不發請求）。

## Impact

- Affected specs: `save-pdf`（新）、`non-interference`（新增 requirement）
- Affected code:
  - `Sources/SafariBrowser/Commands/SavePDFCommand.swift`（新）
  - `Sources/SafariBrowser/Utilities/TabPDFReader.swift`（新）
  - `Sources/SafariBrowser/Utilities/SavePDFFailure.swift`（新）
  - `Sources/SafariBrowser/Utilities/Errors.swift`、`Sources/SafariBrowser/SafariBrowser.swift`、`Sources/SafariBrowser/Commands/TargetOptions.swift`、`Sources/SafariBrowser/Utilities/PDFCacheFailure.swift`、`Sources/SafariBrowser/Utilities/PDFCacheOutput.swift`
  - `Tests/SafariBrowserTests/TabPDFReaderTests.swift`、`Tests/SafariBrowserTests/SavePDFCommandTests.swift`（新）、`Tests/e2e-save-pdf.sh`（新）、`Tests/mcp-stdio.py`、`Makefile`
  - `README.md`、`CHANGELOG.md`、`CLAUDE.md`
