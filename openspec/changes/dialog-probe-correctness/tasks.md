## 1. 探測核心

- [x] [P] 1.1 帶目標與期限的 gate：實作 Expiring keyed verdicts，移除 last/current、加入 state(for:) 與 throwIfBlocked(key)、none 改 clear、probe 移到鎖外；測試跨視窗與 TTL 到期不得誤阻擋。Refs #137, #135。
- [x] [P] 1.2 有界 worker 與可測樹走訪：實作 Bounded complete probing，提供可注入 provider、單 worker 與 單次最多 100 ms、每指令共 200 ms 的等待預算；測試各 IPC 阻塞、讀取失敗、depth3、截斷、late result 與 busy 不排隊。Refs #135, #138。

- [x] 1.3 依 #126 Errata 實作每邏輯指令 200 ms 總預算：gate 預留與結算 probe 時間，InProcessStepDispatcher 每步重置預算；測試預算耗盡不再呼叫 provider、下一步恢復預算。Refs #135。

## 2. 身分與指令整合

- [x] 2.1 穩定視窗身分與入口涵蓋：實作 Stable target probing，保留 WindowInfo.windowID，位置 target 先取得 ID，AX 不猜順序；測試順序倒置、設定／Inspector 插入、零 ID 與失敗。Refs #134。
- [x] 2.2 將 Expiring keyed verdicts 接到 JS 初次／retry、空文字與失敗路徑，取消全 app 誤歸因；以不同目標 dialog 與過期結果測試。Refs #137。
- [x] 2.3 實作 Native command warnings：native resolver 與 tabs --window 在動作前探測；測試各入口涵蓋、警告一次與 stdout 不變。Refs #133。

## 3. 測試與交付

- [x] 3.1 可驗證的 e2e：實作 Honest probe tests，計時依賴／非整數／mktemp 失敗不假通過，debug=1 量測每指令累計≤200 ms，cleanup 與 dismiss 同用 nonce 所有權、GUI 鎖定前置檢查；Unicode／全換行／URL target 補斷言。Refs #138, #135。
- [ ] 3.2 【非 GUI 與先前四視窗 ID 對照已完成；目前 GUI 鎖定，等待最終 Safari 實測】跑完整單元測試、smoke、真實 Safari fixture 與多視窗 ID 對照，更新 README／CHANGELOG；以 spectra analyze／validate 確認契約一致。Refs #134, #137, #135, #138, #133。
- [ ] 3.3 凍結提交、獨立交叉驗證、逐 issue 同步狀態與 checklist，建立承接 daemon 修正的 PR；不 merge、不 close。Refs #134, #137, #135, #138, #133。
