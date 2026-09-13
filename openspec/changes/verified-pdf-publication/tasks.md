## 1. 獨立實作

- [x] [P] 1.1 Private staging and atomic publication：實作 PDFExportDeadline／PDFExportTransaction，私有 staging、coherent PDF 快照、獨立 inode 原子發布與 no-replace；以真實暫存檔測延遲／截斷／舊 PDF、來源變動、權限、symlink、late race、取消與期限。
- [x] [P] 1.2 Single deadline native script：共用導航加入 PDF 專用期限、owner／staging 檔名檢查，單次 Save 後輪詢結束或拒絕額外確認；以實際生成 AS 控制流程的外部操作 stub、osacompile 與共享片段測試驗證，保留 upload 預設行為。

## 2. 整合與驗收

- [x] 2.1 Effective path and command integration：PdfCommand 接上 transaction，保留 allow-hid／overwrite 預檢，nativeExporter 僅替換 native 邊界；測無副檔名、明確副檔名、實際 stdout、MCP schema 與來源錯誤不發布。
- [x] 2.2 Export page as PDF 與 Native file confirmation authorization：同步主規格／README 的 staging、成功、symlink 與授權契約；自有 GUI 驗新檔、no-extension、explicit-extension、overwrite、晚到目的檔保留與清理，未實測不得標 verified。
- [x] 2.3 完整回歸、交叉審查、嚴格 Spectra 驗證與逐 issue/PR 狀態同步；保留所有實機與推論的證據界線。
