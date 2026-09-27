## 1. 獨立生命週期元件

- [x] [P] 1.1 新增 DaemonConnection.swift 與 DaemonConnectionTests.swift，實作「單一描述元 owner 與非同步 nonblocking I/O」及 Connection descriptor access and closure have one owner：短鎖串行 syscall／撤銷／close、EAGAIN 鎖外原生就緒通知、私有 CLOEXEC monitor 在 cancel handler 關閉、SIGPIPE／adopt 失敗清理；以 socketpair、慢 peer、同 fd 重用、並行撤銷與 close-once 的 RED／GREEN 驗證。
- [x] [P] 1.2 新增 DaemonRequestCompletion.swift 與 DaemonRequestCompletionTests.swift，實作「可取消完成等待與未完成工作追蹤」所需單次 result/cancel 仲裁：等待取消不 join 非合作工作、晚到結果不保存；以取消先到／結果先到／並行完成／payload 釋放的 RED／GREEN 驗證。

## 2. 連線與請求整合

- [x] 2.1 在 Instance 實作「連線登記與 dispatch 接納」及 Accepted connection revocation prevents new dispatch：改成 Connection ID／世代 registry，停止撤銷 owner，讀取與解析後在同一 actor turn 檢查並接納 handler；三個 DaemonEstablishedConnectionTests 原始 RED 轉 GREEN，補 buffered 第二請求與 stop/start 的拒絕測試。
- [x] 2.2 串接可取消完成等待與獨立 operation 登記，履行 Completed transport and request work retires by identity 與 Daemon run cleanup is generation owned：transport 先完成、非合作 handler 如實追蹤直到返回、舊結果不回覆或清除新登記；用受控 handler gate、長時間連線 churn、並行停止驗證。
- [x] 2.3 實作「單一回覆與 shutdown 等待預算」及 Shutdown replies preserve framing and bounded progress：單次 reply claim、先嘗試 ACK、250 ms ACK 與另 250 ms 共用取消寫入期限、snapshot 不持裸 fd；以正常結果／cancel 競爭、partial write、慢讀 peer、原 lifecycle／no-replay 測試驗證。
- [x] 2.4 完成「Reader 與記憶體證據」：共用 framing 核心與 async I/O adapter，保留超量／EOF／EINTR／合併行語意；跑 DaemonRequestBoundsTests，量測大型 request churn 的追蹤／持有釋放與實際 footprint，明確區分邏輯 bytes 與 Foundation capacity。

## 3. 驗證與交付

- [x] 3.1 整合 #198 最終基底後執行完整 daemon tests、關鍵撤銷／ID／reply guard 變異與 make test-all；比較自有 warm RPC 延遲，證明正常回覆、不重播、停止有界與資源退休，保留原始量測紀錄。
- [ ] 3.2 更新 CLAUDE.md／CHANGELOG.md，完成 spectra analyze／validate、六方確認與規格同步歸檔；PR 和每個提交引用 #199，報告所有仍未完成的實機或審查條件。
