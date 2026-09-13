## Problem

PDF 指令返回時不保證檔案已完成，固定 0.5 秒檢查也會漏掉稍後出現的面板。無副檔名會另存成 `.pdf`，明確非 PDF 副檔名會產生額外確認，現行流程卻將所有 nested sheet 當成覆寫。

## Root Cause

原生 UI 的操作已送出與檔案可供使用混成同一個成功條件；目的檔直接由 Safari 寫入，無法以既有檔案存在證明本次輸出完成。

## Proposed Solution

先匯出到新建私有目錄的唯一 `.pdf`，等待原生面板結束與可讀的完整 PDF 快照，再以獨立檔案原子發布。沒有 overwrite 時使用原子 no-replace；有 overwrite 才替換目的項目。所有等待共用 60 秒預算，沒有重播 Save 或猜測確認。

## Capabilities

### New Capabilities
- verified-pdf-publication: 完整快照、原子發布與共同期限。

### Modified Capabilities
- pdf-export: 匯出目的地、成功條件及 staging 原生流程。
- non-interference: 區分原生 staging 確認與最終 filesystem overwrite 授權。

## Impact

PdfCommand、共用 file-dialog script generator、PDFExportTransaction helper、檔案／腳本測試與 README。既有 upload 行為不變；不執行 Print、不移除 HID。
