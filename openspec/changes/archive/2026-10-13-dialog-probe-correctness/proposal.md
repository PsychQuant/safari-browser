## Why

#134、#137、#135、#138 與 #133 共用同一條 dialog 探測路徑：位置猜測可能探錯視窗，全域最後結果可能誤阻擋另一目標，AX 讀取失敗被當成沒有 dialog，探測又沒有整體時間上限。先修正判定來源，再擴充入口涵蓋面。

## What Changes

- 只用已解析的穩定 window ID 配對 AX 視窗；沒有可信 ID 就回報 unprobed，不猜 AX 陣列位置。
- gate 改成帶 key 與單調時間 TTL 的查詢；none 改名 clear；移除無目標的最後結果歸因。
- 入口探測透過有界執行器限制呼叫端等待，worker 未結束前不增加工作；樹讀取失敗、截斷與逾時回 unprobed。
- 將探測樹抽成可注入 provider，涵蓋視窗識別、完整走訪、文字與按鈕讀取的測試。
- native resolver 與 tabs --window 補入口警告；維持唯讀成功與 stdout 格式。
- e2e 計時、前置檢查、debug、nonce 所有權檢查與暫存目錄改成可驗證行為。

## Capabilities

### New Capabilities

- `blocking-dialog-probe`：視窗身分、判定有效期限、探測預算與指令涵蓋契約。

### Modified Capabilities

無。

## Impact

SafariBridge、BlockingDialogGate、新 probe provider／worker、TabsCommand、e2e-dialog 與相關單元測試。承接 #130／#136；不處理 #114 的完整控制字元清理，也不自動 dismiss 原生 dialog。
