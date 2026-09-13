## Why

#156：呼叫端先驗證的 fixture 身分沒有傳到 dismiss，跨程序交接可能採納新 dialog。

## What Changes

- 增加可選、成對的 expected window ID／raw message。
- 在初始訊息與實際 press snapshot 上拒絕不匹配對象。
- #131 harness 傳入身分，補交接替換測試。

## Capabilities

### New Capabilities
- `guarded-dialog-expectations`: 呼叫端可約束 dialog dismissal。

## Impact

DialogDismissCommand、SafariBridge.pressDialogButton、DialogPressExecutor 與既有背景 fixture。未指定期望者保持原行為。
