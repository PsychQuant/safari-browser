## 1. Independent work
- [x] [P] 1.1 #122：實作 Shared signature assessment 與 Durable guidance；保留 guard 行為與所有 mutation、重現路徑注入。
- [x] [P] 1.2 #119/#121：實作 Atomic installation evidence 的暫存目錄 integration regression，驗證 staging／失敗／fresh inode／舊 process。
- [x] [P] 1.3 #124：同步 build-and-install 與 local-data in-flight artifacts，維持不改預設 install 的原始理由。

## 2. Integration
- [x] 2.1 #123：落實 Maintained signing entrypoints，移除舊 target 及有效 caller，更新 migration 文件。
- [x] 2.2 #119/#121/#122/#123/#124：strict suite、mutation、atomic install、完整 test-all、實際 FDA 狀態核對。
- [x] 2.3 凍結提交、六位交叉審查、PR 與 #119/#121/#122/#123/#124 verified 狀態同步。

2.2 程式驗證：runtime 路徑注入 regression 先紅後綠、strict 52/52、mutation 18/18、atomic install 7/7 通過。已安裝 binary 的 signature guard 與 history 查詢皆 exit 0；唯讀資料庫檢查未找到明確紀錄；使用者已另行確認「已單獨加入」，人工事項依此確認完成，不把查詢成功冒稱為資料庫授權證據。

最終驗證：R1六位獨立CODE PASS；R2獨立Codex與補充代理PASS。Claude R2原派發／重試均受額度限制，五個角度由coordinator依IDD recovery自審，報告明列process gap。R2 entrypoint3項、strict52/52、mutation18/18、atomic7/7及test-all（981Swift）通過。
