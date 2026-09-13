## Why

#128 的全視窗探測逐次累積 AX IPC 逾時，15 個視窗曾耗時 18 秒。舊 collector 也會把讀取失敗或截斷當成沒有 dialog，無法用縮短 timeout 的方式直接修好。

## What Changes

- 全視窗讀取使用最多 800 ms 的 caller 等待預算，並與入口探測共用單一在途 AX 工作協調器；忙碌時直接回報無法確認。
- 用明確的完整／不完整全視窗快照取代 Optional collector，保留單一、多個、沒有、權限不足與 session 不可用的區分。
- list、失敗路徑與 dismiss 重新檢查採共用走訪及訊息／按鈕快照；未完整讀取或檢查逾時不得按鈕。

## Capabilities

### New Capabilities
- `global-dialog-inspection`: 全視窗探測的時間、完整性與安全重新讀取契約。

### Modified Capabilities
無。既有入口探測的時間與目標契約保留。

## Impact

SafariBridge dialog helpers、BoundedDialogProbe、DialogCommand、Errors，以及新增的共用 worker／scanner。單元與自有 Safari fixture 驗證；不新增依賴。
