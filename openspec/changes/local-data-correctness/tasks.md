## 1. Parallel implementation
- [x] [P] 1.1 #111/#112/#113/#117：Private consistent snapshots、Honest source errors、Complete bounded query，SQLite/storage回歸。
- [x] [P] 1.2 #115/#116/#120：Explicit parser coverage、Bookmark search，四Commands接memory APIs，parser/exit/stream測試。
- [x] [P] 1.3 #114：Safe text boundaries，四formatRow與dialog/error renderer，控制字元/引號/截斷測試。
## 2. Integration
- [x] 2.1 同步README/CHANGELOG/現有local-data規範，完整測試、mutation與安全實測。
- [x] 2.2 凍結提交、獨立審查、PR與八個issue狀態同步。

整合補充：實際 Bookmarks 有15個合法空List省略Children，已補測接受；另2個空URL leaf仍明確警告。極端有限日期與BCE會被Foundation夾成錯日期，改以共用可表示日期檢查輸出null。物理損壞SQLite晚期leaf測試確認memory snapshot內取滿10列即停止，完整掃描仍明確失敗。SIGINT/SIGTERM/SIGKILL各對SQLite/plist執行6次中斷，均無新disk copy。

完整test-all：1009 Swift tests、7 runner、66 smoke、9 harness、3 signature entrypoint、52 signature assertions及daemon/memory interruption通過。GUI dialog27/27無skip；CloudTabs本機不存在，schema由合成fixture驗證。Bookmarked空List修正與optional dates/since回歸通過。

R1找到SQLite附屬檔ENOENT誤報正常缺檔，以及未覆蓋checkpointed WAL無sidecar。本機原行為重現2個失敗；R2改為初次open限定absence，加入OFD受鎖fallback。20項storage/SQLite測試、9次含持鎖backup的signal中斷、完整1013 Swift test-all通過。

R2六份跨模型審查通過；R3補充明確拒絕原因、晚期ENOENT分類與受鎖回歸，獨立Codex及安全補審皆通過。最新21項storage/SQLite測試、完整1014 Swift test-all通過；9次signal中斷涵蓋受鎖backup。GUI 27/27於R1執行，後續僅修改storage/error分類，dialog renderer未變。PR #149保留逐issue驗證紀錄；本次停在verified，合併與結案另行處理。
