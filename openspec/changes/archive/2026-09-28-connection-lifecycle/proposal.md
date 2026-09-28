## Problem

#199 的已接納 client 在 stop 後仍可卡住讀取，收到晚到資料時還會啟動 handler；已完成 task 也留在 connectionTasks，直到下一次 stop 才清空。

自有 socket 重現得到三項失敗：stop 後送入 fixture RPC 仍執行一次、無輸入 client 的 read 逾時而非 EOF、三條已完成連線的追蹤數仍為 3。基底包含 #198 的 Run／shutdown 世代修正，但那不會撤銷一般連線 I/O。

## Root Cause

取消只改 Swift task 狀態，不會中斷 blocking read；讀取後至 dispatch 沒有原子撤銷守衛。actor 只保存 task 陣列，fd 由 serveConnection 的 defer 持有，stop 沒有可安全喚醒它的描述元所有權；正常完成也沒有退休通知。以裸 fd 快照寫入取消回覆會與 fd 重用及一般回覆寫入競爭。

## Proposed Solution

以唯一 Connection ID 與單一描述元 owner 管理接納連線；讀寫採 nonblocking socket，所有 syscall 與撤銷／shutdown／close 以同一短鎖串行，遇到 EAGAIN 則在鎖外進行可取消的非同步等待。鎖內不等待 I/O，因此停止不用跨執行緒關閉別人仍在 blocking read 的裸 fd。actor 在同一個 turn 檢查連線與世代並接納 handler 工作；完成與停止回收按 ID 比對。

把 transport 等待與已接納的 handler 工作分開：停止能完成連線 task／釋放 reader，取消尚未開始的工作；已開始且不合作的工作保留自己的追蹤直到真正返回，不假裝副作用撤銷，也不重播。以單一 request reply claim 避免正常結果與 cancellation envelope 交錯。shutdown ACK 與取消回覆採總等待預算，隨後執行原有停止流程。

## Success Criteria

- 三項現有重現轉為通過；無輸入與慢讀 peer 的 transport 在停止後有界完成。
- 撤銷後不得接納新 handler；已開始工作的晚到結果不能寫入新連線或移除新追蹤項目。
- 反覆連線在 daemon 持續運作時退休完成 task；reader／請求持有與記憶體量測如實區分邏輯所有權和實體配置。
- 不以跨執行緒裸 close 喚醒 I/O；fd 重用與 reply 競爭有實際 socket 測試。
- lifecycle 正常回覆與 cancelled／結果未知分類、不重播、#194 request 上限與 #198 listener／Run 契約保留。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `persistent-daemon`: 已接納連線撤銷、有界 transport 完成、世代與描述元所有權、工作退休及 shutdown 回覆順序。

## Impact

- Sources/SafariBrowser/Daemon/DaemonServer.swift
- 新增 Sources/SafariBrowser/Daemon/DaemonConnection.swift 與 DaemonRequestCompletion.swift。
- Tests/SafariBrowserTests/DaemonEstablishedConnectionTests.swift、新 helper 測試，以及既有 daemon lifecycle／framing／deadline 測試。
- CLAUDE.md、CHANGELOG.md、persistent-daemon 規格。
- 依賴 #198 PR #204；目前先診斷與訂規格，實作整合前確認其最終基底。
