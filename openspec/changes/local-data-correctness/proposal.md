## Why
#111–#117 與 #120 涵蓋資料讀取、快照一致性、解析、輸出與搜尋。逐檔複製 SQLite/WAL 不是一致快照，且將受保護資料留在不受 TCC 保護的暫存區。
## What Changes
- SQLite Backup API 備份至記憶體、plist 直接讀取記憶體，移除磁碟暫存複本。
- 保留來源 errno，區分缺檔、FDA、I/O 與解析錯誤；錯誤使用來源路徑。
- 四 parser 明確處理必要欄位與部分壞資料；history 取滿 limit 停止，不再掃描無關列。
- 統一文字欄位與 dialog 訊息的控制字元／引號／長度處理，JSON 保留資料。
- Bookmarks 新增 title/URL 大小寫不敏感搜尋，與 folder filter 合併。
## Capabilities
### New Capabilities
- `local-data-snapshots`: 私密一致快照、錯誤保真、解析與輸出契約。
### Modified Capabilities
無；同步既有 in-flight local-data-query 的過時描述。
## Impact
SafariDataStore、SQLiteReader、四個 local-data commands、LocalDataOutput、dialog/error renderers、回歸測試與規範。
