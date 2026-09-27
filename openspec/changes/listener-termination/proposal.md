## Why

#198 指出永久 accept／poll 錯誤只結束內層迴圈，外層仍保留 pid／running 狀態直到 idle timeout。新增通知還必須處理啟動尚未完成、並行停止與通知延遲，避免舊清理刪掉新啟動的資源。

## What Changes

- 內層以固定 operation／errno 表示永久 listener failure，關閉自己持有的 listener／wake-read，再通知所屬啟動世代。
- Instance 以 listener generation 保護內層清理；外層以每次啟動的 Run 識別碼、共享 startup／teardown 工作和 waiter 集合管理生命週期。
- 新啟動等待前次清理完成；舊 listener、shutdown callback 與 watchdog 通知只作用於原 Run。
- waitUntilStopped 回傳明確原因；daemon __serve 在永久 listener failure 時以去識別化錯誤非零結束，正常 shutdown／idle 保持正常退出。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `persistent-daemon`: 永久 listener failure、世代所有權與停止通知契約。

## Impact

DaemonServer.swift、DaemonPaths.swift、DaemonServeLoop.swift、DaemonCommand.swift、daemon 生命週期測試、CLAUDE.md／CHANGELOG.md 與 persistent-daemon 規格。不改自動重新啟動、RPC 重播、GUI 或既有阻塞連線取消（#199）。
