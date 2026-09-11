## Why
#141 的 daemon shutdown watchdog 能提早結束嵌入式測試且 exit 0；#143 的 exec request 遺失呼叫端探測設定；#144 的 GUI 鎖定狀態被誤報成沒有 dialog／Safari 視窗。前一批探測修正已合併，現在補足這些邊界。

## What Changes
- 生產 daemon 明確啟用五秒強制退出 watchdog，嵌入式 Instance／Server 預設不結束宿主程序；完整測試須有完成證據。
- Exec envelope 只攜帶 opt-out/debug 兩個布林探測選項，request-local gate 使用呼叫端值，缺欄位的舊 client 保留 daemon 預設。
- 共用 GUI session 判定；dialog list／dismiss／capture 對鎖定或不可用 session 回報明確錯誤，不誤稱沒有 dialog。

## Capabilities
### New Capabilities
- `daemon-probe-lifecycle`: daemon 嵌入生命週期、exec 探測選項及 GUI session 診斷的邊界契約。
### Modified Capabilities
無。此契約補充 script-exec、persistent-daemon 與現有探測的操作邊界。

## Impact
DaemonServer、DaemonServeLoop、DaemonCommand、DaemonRequestContext、DaemonDispatch、ExecCommand、SafariBridge、DialogCommand、GUI session utility、測試 runner 與 Makefile。無新套件相依。
