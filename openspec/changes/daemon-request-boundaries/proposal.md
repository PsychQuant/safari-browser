## Why

#130 的 daemon 請求等待時間超出既有 15 秒契約，socket 逾時又被誤報為空回覆；#136 的 exec 成功步驟警告遭丟棄，daemon 內則共用全行程警告狀態。這使自動化卡住且無法知道頁面正在等待對話框。

## What Changes

- 連線、握手、傳送與完整回覆共用單調時鐘期限；一般請求預設 15 秒，exec 明確採 60 秒。
- **BREAKING**：完整請求送出後的逾時、斷線或無法驗證的回覆，回報結果未知並禁止自動重送。連線失敗、握手不相容、未知方法仍可退回一般執行。
- exec 每次請求使用獨立 dialog gate、診斷訊息收集器與內部 AppleScript 執行器；保留預先編譯快取，避免再次連回自己的 socket。
- 回覆協定增加可選 diagnostics 陣列，client 在輸出結果前轉發 stderr；成功與失敗回覆皆適用。
- 子行程 stdout/stderr 同時讀取，成功也轉發警告。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `persistent-daemon`：請求期限、可重試條件與診斷訊息回傳。
- `script-exec`：每次請求的狀態隔離、直接內部執行與 stderr 傳遞。

## Impact

- `DaemonClient.swift`、`DaemonRouter.swift`、`DaemonServer.swift`、`DaemonDispatch.swift`、`ExecCommand.swift`、`CommandDispatch.swift`、`SafariBridge.swift`、`BlockingDialogGate.swift` 及相關測試。
- 不新增外部套件。PR 承接 #126 的已提交版本；不合併或關閉 issue。
