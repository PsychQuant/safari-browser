## Context

#160 已實測 CLI 返回後才寫入 PDF、無副檔名自動追加 .pdf；明確 .txt 副檔名會出現額外確認而被錯誤分類。#107 的不重播及獨立 overwrite 授權必須保留。

## Goals / Non-Goals

Goals：成功時目的路徑已含可讀的完整 PDF 快照，且 Safari 不再持有該目的 inode；既有 PDF、ACK、靜默間隔均不能冒充完成。No overwrite 的晚到競爭必須由 filesystem 原子操作拒絕。

Non-Goals：不取代 #101/#102 的 HID 路徑、不操作 Print、不新增背景服務、不保證作業系統 syscall 在故障 filesystem 上具硬即時性。

## Decisions

### Private staging and atomic publication

PDFExportTransaction.run(destination: URL, overwrite: Bool, timeout: TimeInterval = 60, exporter: (URL, PDFExportDeadline) async throws -> Void) async throws -> URL 為唯一生命週期入口。PDFExportDeadline 使用 DispatchTime 單調時鐘，提供 remaining() throws 與 check() throws；無效／非有限 timeout 拒絕。

使用 mkdtemp 或等價 exclusive create 建立 0700 私有目錄與唯一 .pdf 路徑，不重用既有 staging。exporter 完成後，等待 staging 產生完整快照。複製來源時比對同一 fd 的 identity／size／時間與路徑 generation；來源改變則放棄該次快照、在原期限內再觀察，不重播 exporter。快照必須有 PDF header、結尾 EOF 與可由 CoreGraphics 讀取的非零頁數。複製採有界 buffer，不用 mmap 讓可變來源穿透快照，也不用固定靜默間隔宣告完成。

以獨立 inode 發布已驗證快照，禁止直接 rename Safari 的 staging inode。最後一次發布使用目的 parent 內 exclusive 0700 sibling directory 中的快照與原子 rename/no-replace；chmod 在私有目錄內完成，避免發布前暴露最終權限；no-overwrite 的 late EEXIST 不得降級成覆寫。目的 parent 以 directory fd 綁定；每個 publication 最多一次，失敗／未知結果不重播。

PDFExportTransaction.validateDestination(path: String, overwrite: Bool) throws 保留 NUL、目錄、symlink→directory 與無法查驗的拒絕，另拒絕特殊檔案。overwrite 替換所指定 directory entry；symlink→regular/dangling entry 可被明確取代，並不改寫其 referent。新檔沿用 staging 的一般檔案權限，既有 regular 目的檔保留其權限；暫存項目在發布前保持私有。錯誤／取消皆清理自有暫存項目，目的檔在 publication 前維持原狀。

### Single deadline native script

PdfCommand 保留一個 osascript，預算從 transaction 傳入。Menu、Go to Folder、初始 Save、面板結束共用 deadline；外層 subprocess watchdog 使用剩餘預算。共用導航產生器可增加 save 專用選項，但 upload 預設片段行為不變。Save 前比對唯一 staging 檔名；用 Safari 原生 window ID／URL 在 menu、按鍵與 terminal polling 前確認原目標仍在，不以其他前景視窗無 sheet 當作成功。

staging 路徑從未存在，任何額外 nested 確認都屬異常並拒絕；沒有 native Replace 重播。只有觀察到原生面板結束才返回 exporter。保留剪貼簿 success/error restore；程序被 watchdog 終止時明示面板／剪貼簿可能需人工復原。

### Effective path and command integration

字串先檢查 NUL／目錄語意，再展開 tilde 與相對路徑。沒有副檔名時追加 .pdf；已有副檔名則保留。這保留已測得的無副檔名行為，同時尊重明確檔名並透過 staging 避免 Safari 額外格式確認。validate 在任何 GUI 前完成。成功 stdout 回報經終端安全跳脫的實際目的路徑。

既有 nativeExporter 測試 seam 只替換 native 邊界，現在收到 staging 路徑；不得再跳過 transaction。CLI／MCP 保持 --allow-hid 與 --overwrite 門檻，unknown/error 不會成功發布。

## Implementation Contract

run 的 exporter 回傳只代表原生階段結束；helper 仍須取得 coherent、valid PDF 快照並成功原子發布。舊有效目的 PDF、空／截斷／延遲 staging、來源換 inode／複製中變動、取消／timeout、late destination collision 都要有真實 filesystem 測試。腳本透過純 AS 外部操作 stub 驗證延遲轉換／共同期限／不重播，並用 osacompile 檢查 production。實機須驗 no-extension、explicit-extension、新檔、overwrite、原檔保留與清理。

## Risks / Trade-offs

私有暫存與快照增加一次檔案複製，換取已完成的獨立輸出；不把 Safari 後續可能寫入的 inode 交給消費者。symlink leaf 是替換 entry 的明確契約，必須在 README 說明並測試。既有原生 panel 出錯後可能殘留，仍需明確取消，不能為清理而自動重播確認。
