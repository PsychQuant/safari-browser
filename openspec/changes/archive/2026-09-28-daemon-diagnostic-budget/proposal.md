## Why

#197 的每 incident 首筆／每 64 筆記錄仍會在失敗與成功交替時產生大量日誌。#194 的請求超量與讀取失敗也缺乏不含請求內容的拒絕診斷，需要共用且有明確總量上限的事件管道。

## What Changes

- 單一 Instance 的診斷事件使用 8 筆突發額度、每秒補充 2 筆的共用 token bucket；一般事件保留最後 1 筆額度給終止原因。
- 被抑制的候選紀錄保存固定分類計數、第一筆抑制事件及最後的恢復／終止原因；合併進下一筆可送出的事件，或由單一 500 ms 定時工作送出摘要。
- accept、連線初始化與 request 拒絕事件共用額度，維持固定事件名稱與整數原因，不寫入 source、URL、requestId 或前綴。
- writer 在 actor 外執行，stop 不等待額度、timer 或 writer；關閉／更換 logger 使舊 timer 失效。已送出或程序終止時的日誌仍沿用既有 best-effort 語意，不新增持久化保證。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `persistent-daemon`: 新增跨 incident 的診斷事件速率、抑制摘要及 logger 生命週期契約。

## Impact

- `Sources/SafariBrowser/Daemon/DaemonDiagnosticBudget.swift`：固定事件分類與有界預算／摘要狀態。
- `Sources/SafariBrowser/Daemon/DaemonServer.swift`：共用 gate、定時摘要、request 拒絕記錄與停止清理。
- `Sources/SafariBrowser/Daemon/DaemonLog.swift`：去識別化摘要格式。
- `Tests/SafariBrowserTests/DaemonDiagnosticBudgetTests.swift`、既有 daemon 測試：控制時鐘、真事件路徑及停止／替換 logger 驗證。
- `CLAUDE.md`、`CHANGELOG.md`、persistent-daemon 規格：額度、保留欄位與 best-effort 邊界。
