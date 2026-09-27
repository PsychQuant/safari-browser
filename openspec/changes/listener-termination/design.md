## Context

Instance.acceptLoop 在永久錯誤時關閉 listener，但外層 Server 的 running／pid／waiter 狀態不變。新的通知不能依賴同步診斷 writer，也不能讓 stop 的 actor 重入在新啟動後繼續刪除路徑。

## Goals / Non-Goals

**Goals:** 永久錯誤及時結束所屬 Run、保留 typed operation／errno、清理自有路徑、完成所有屬於該 Run 的 waiter，並隔離晚到的 callback／watchdog。

**Non-Goals:** 不自動重啟、不重播 RPC、不改編譯快取／handler 的工作契約；已建立連線的阻塞讀取取消仍屬 #199。沒有任意系統負載下的硬牆鐘保證，測試使用可控排程與自有本機資源。

## Decisions

### Listener 結果與世代通知

新增 Sendable／Equatable 的 ListenerFailure（operation 僅 accept 或 poll，加 Int32 errno），只在既有 acceptDisposition.stop 類別產生。正常 wake／取消與可恢復錯誤不發永久失效通知。每次 Instance.start 產生 listener generation；failure cleanup 比對世代後才能 stop 該 Instance，並呼叫當次 start 捕捉的 onListenerFailure。stop 使世代失效。

先由讀取迴圈唯一持有者關閉 listener／wake-read，再處理 failure。終止診斷仍通過 #197 預算，但 writer 不能阻擋 failure notification；已準備的固定 emission 可獨立 best-effort 寫入。對外 callback 延遲時，內層資源已清理；舊 callback 不能讀取後來改寫的 mutable hook。內部 AcceptEnvironment 增加可控制的 beforeFailureNotification，正式預設立即繼續，用於重現晚到通知。

### PID entry 所有權

DaemonPaths.writePidFile(record:at:) 從建立的 fd 捕捉 device/inode，回傳 EntryIdentity（discardable），並以 close-on-exec 的共享描述元持有原 inode，避免 unlink 後的 inode 回收重用。短寫／寫入失敗在 helper 內清理仍屬於自己的 entry；無法確認身分時保留。清理只移除仍與該 identity 相符的 pid entry；已被替換或無法確認的 entry 保留。此檢查防止已觀察到的替換與世代延遲，不宣稱在任意同 UID 惡意競態下提供原子 compare-and-unlink。legacy integer pid helper 保持原介面。

### 外層 Run 狀態與串行清理

Server 保留共享 underlying／cache，另以 actor-confined Run 保存 UUID、starting/running/stopping/stopped、路徑／pid identity／log handle、startupTask、teardownTask、StopReason 與 waiter 集合。並行 start 等待同一 startupTask；stopping 時的新 start 等待同一 teardownTask，清理完成前不能重用路徑。所有 await 後都重新確認 Run 身分與 phase。

Stop 設定該 Run 的第一次原因、取消 startup/watchdog，並建立一次 teardownTask。它先等 startup 工作結束（防止晚到 bind），再停止 underlying，停用 logger、清理該 Run 的 pid／log handle，最後恢復其所有 waiter。不能 await accept loop 或診斷 writer。內層 stop 負責 socket unlink，外層不再重複 unlink 可能已被替換的 socket。

啟動失敗必須走同一清理流程。若 listener 在 startup 返回前失效，start 不得在清理後再宣告 running；該 failure 保留於 Run，start 以 typed failure 結束。為驗證取消邊界，內部 lifecycle scheduling hook 允許在 bind 前暫停，正式預設無延遲。LifecycleEnvironment 同時提供不改狀態的事件觀察、可控制 watchdog clock/sleep 與清理排程，讓測試確認已註冊 waiter／已加入 startup 或 teardown 後才釋放 gate，不靠任意 sleep 猜測交錯。

### 原因與舊工作隔離

StopReason 區分 requested、idleTimeout、startupFailed、listenerFailed。waitUntilStopped 回傳所註冊 Run 的原因，已停止時回傳最近完成原因；多個 waiter 不互相覆蓋。shutdown hook、watchdog 與 listener callback 均捕捉 Run ID，只有仍擁有 current Run 者能停止它。第一個已接受的停止原因不被晚到原因覆蓋。

__serve 等待結果若為 listenerFailed，拋出只含固定 operation／errno 的錯誤，非零退出；正常 stop／idle 仍正常退出。pid/socket 的單獨身分保護與 Run guard 不改既有同 UID IPC 信任模型。

## Implementation Contract

Instance.start 新增預設為 nil 的 onListenerFailure async callback，並保留既有環境注入。ListenerFailure 為 Error／Sendable／Equatable／CustomStringConvertible，沒有路徑、source、URL 或 requestId。直接 acceptLoop 的既有測試仍能觀察其 diagnostic sink，不需放寬 #178/#197 斷言。

EntryIdentity 提供從 fd 建立與條件式移除 path 的內部介面。Server.start 保留既有必要參數，新增預設正常的 AcceptEnvironment／startup scheduling 注入；正式 CLI 使用預設。Server.waitUntilStopped 標記 discardableResult 以保留既有忽略回傳值的 caller。

驗收：永久 accept/poll 各自失效、正常 wake／cancel 不誤報、阻塞 writer 不延後 failure callback、已被替換 pid 保留；外層即時故障／startup 故障、兩個 stop／多 waiter、新 start 等 teardown、晚到 listener／shutdown／watchdog 不影響新 Run；實際新 client 的 status 成功及 CLI failure 非零分類。完整測試與六方確認後同步規格並歸檔。

## Risks / Trade-offs

- [啟動中的 actor 重入] startupTask 與 teardownTask 必須避免互等 → startup 只建立／檢查，不在自身 task 內等待 teardown；外層 caller 負責清理。
- [診斷 writer 卡住] 不得卡住關閉或通知 → listener 先關、診斷寫入不在關鍵等待鏈；終止原因另由 waiter／CLI 呈現。
- [PID 替換] 舊路徑字串不等於所有權 → 從 fd 捕捉 identity，移除前重新比對。
- [停止後既有連線] 不宣稱能中斷 blocking read → 保留 #199 範圍。

## Migration Plan

沒有新的 CLI flag 或 RPC wire 格式；內部 wait 結果新增 typed reason，__serve 的永久錯誤退出碼改為非零。回退本變更恢復原來等 idle timeout 的行為。

## Open Questions

無待決事項；依 /idd-all unattended 的既有授權接續實作與驗證。
