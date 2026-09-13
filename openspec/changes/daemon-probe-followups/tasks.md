## 1. Independent fixes
- [x] [P] 1.1 #141：實作 Embedded shutdown isolation 與 Complete test evidence；shutdown watchdog 僅由正式入口注入，嵌入式存活測試與完整 suite runner／假成功回歸。
- [x] [P] 1.2 #143：實作 Request-local probe options；限定 exec dialogProbe envelope、request-local 選項、legacy default／布林型別／跨 request 回歸。
- [x] [P] 1.3 #144：實作 GUI session evidence；共用 GUI session 判定，dialog scan／press、capture 與 scoped provider 整合、session regression。

## 2. Integration
- [x] 2.1 更新 README／CHANGELOG，執行完整 Swift、runner、smoke、daemon 與 Safari fixture 驗證。
- [x] 2.2 凍結提交、獨立交叉審查、建立 PR 並同步三個 issue 至 verified。

驗證快照 1698658：981 Swift tests 單一程序完整通過，7 runner／66 smoke／9 harness checks 通過；正式 daemon 在阻塞 AppleScript 下 5.077 秒退出。Safari fixture 27/27、無失敗或略過且 cleanup exit 0。R1 六位獨立審查皆 CODE PASS；PR #146 承接三個 issue，完成紀錄與操作指引另做文件 delta 補審。
