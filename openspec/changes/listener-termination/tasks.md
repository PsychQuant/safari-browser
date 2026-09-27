## 1. 內層結果與檔案所有權

- [x] [P] 1.1 實作 Permanent listener failure terminates its owning run 的 Listener 結果與世代通知：DaemonServer.swift 與新 DaemonListenerTerminationTests.swift，先用永久 accept/poll、取消、延遲 callback、阻塞 writer 的 RED 測試，再驗證 close-before-notify 與同世代一次通知。
- [x] [P] 1.2 實作 Daemon run cleanup is generation owned 的 PID entry 所有權：DaemonPaths.swift 與新 DaemonPidOwnershipTests.swift，從建立 fd 回傳 EntryIdentity，驗證相同 entry 移除、被替換／不明 entry 保留、原 pid 權限與 O_EXCL 行為不變。

## 2. 外層 Run 與 CLI

- [x] 2.1 在 DaemonServeLoop.swift 實作外層 Run 狀態與串行清理，履行 Daemon run cleanup is generation owned；先用永久故障、啟動中停止、並行 stop/start 的測試重現，再驗證 pid/socket 清理與新 client 仍能服務。
- [x] 2.2 實作 Stop completion preserves a typed reason 的原因與舊工作隔離：多 waiter、listener/shutdown/watchdog 綁定 Run ID，DaemonCommand.swift 以固定原因非零結束永久錯誤；驗證晚到通知、首個停止原因及正常退出。

## 3. 整合驗證

- [x] 3.1 執行所有 daemon 相關測試、關鍵 guard／notification 變異與 make test-all，確認不重播、診斷 writer 不阻擋清理、stop 不等待 accept loop；保留 RED／GREEN 與錯誤路徑證據。
- [ ] 3.2 更新 CLAUDE.md／CHANGELOG.md，完成 spectra analyze／validate、六方確認與規格同步歸檔；提交和 PR 引用 #198。
