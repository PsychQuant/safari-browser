## 1. Independent work
- [x] [P] 1.1 #122：實作 Shared signature assessment 與 Durable guidance；保留 guard 行為與所有 mutation、重現路徑注入。
- [x] [P] 1.2 #119/#121：實作 Atomic installation evidence 的暫存目錄 integration regression，驗證 staging／失敗／fresh inode／舊 process。
- [x] [P] 1.3 #124：同步 build-and-install 與 local-data in-flight artifacts，維持不改預設 install 的原始理由。

## 2. Integration
- [x] 2.1 #123：落實 Maintained signing entrypoints，移除舊 target 及有效 caller，更新 migration 文件。
- [ ] 2.2 #119/#121/#122/#123/#124：strict suite、mutation、atomic install、完整 test-all、實際 FDA 狀態核對。
- [ ] 2.3 凍結提交、六位交叉審查、PR 與 #121/#122/#123/#124 verified 狀態同步；#119 的人工 FDA 條件另保留於 2.2。

2.2 程式驗證：runtime 路徑注入 regression 先紅後綠、strict 52/52、mutation 18/18、atomic install 7/7 通過。已安裝 binary 的 signature guard 與 history 查詢皆 exit 0；但未找到該 binary 路徑／識別碼的獨立 FDA 紀錄，人工加入事項等待使用者確認，不把查詢成功當成該事項的證明。
