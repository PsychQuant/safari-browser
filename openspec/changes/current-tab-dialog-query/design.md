## Context

目前 is 系列透過 doJavaScript 查 DOM；#108 需要在 click 自己觸發 confirm 而尚未返回時，有另一個安全查詢。GlobalDialogProbe 與 strict scanner 已能提供有界原生觀察，但全視窗結果不等於目前分頁的狀態。

## Goals / Non-Goals

Goals：提供目前 Safari 主視窗所選分頁的 present／clear／unknown；查詢不依賴 JavaScript 或 Apple Event；沿用共用 AX worker 的 800 ms 總預算與完整性規則。

Non-Goals：不提早中止或重播原 click、不新增自動 dismissal、不切換／activate Safari、不支援 URL 或背景分頁 target、不擴大 exec 的 is 支援範圍，不處理 PDF 完成狀態。

## Decisions

### Bounded current-window observation

新增 CurrentWindowDialogProbe，factory 在 BoundedAXWorker 上建立 AX provider。主視窗只能來自 Safari app 的 AXMainWindow，缺值不得用第一個視窗或標題猜測。新增 provider 的 current-window context，包含 AX node 與允許排除隱藏 pending 的條件；其查詢中每個 AX 讀取共用剩餘期限。

context 的 allowsClear 只有 Safari 作用中、目標非最小化且位於目前可見視窗集合時為 true。無法取得這些條件時保留 false。明確讀到 dialog 可以回 present；沒有讀到且 allowsClear=false 時改回 unknown，不能從隱藏視窗的空樹推論沒有 pending。

DialogTreeScanner 增加可選指定根視窗入口；未提供時保持既有全視窗行為。新 probe 只掃主視窗，仍使用同樣 depth/node budget、WebArea 排除與 incomplete 語意。AX node 不離開 worker。掃描前後讀取 context 與 window ID；身分變更、讀取失敗或期限用盡回 unknown，不採用其他視窗的 dialog。

### Three-state command contract

IsCommand 註冊 IsDialog，新公開呼叫為 `is dialog [--json]`，不接受 selector／TargetOptions。文字 stdout 為 true／false／unknown；present、clear 退出 0，unknown 退出 2，並在 stderr 給原因。JSON 使用既有 WindowDialogStatus 的 state、window_id、messages、reason；unknown 時仍保持有效 JSON 與退出 2。

這是使用者明確要求的唯讀查詢，與 dialog list 一樣不因 automatic entry probe opt-out 而省略。CLI／MCP 共用同一個命令；MCP metadata 自動新增 leaf，必要 golden/count 測試同步，原 is 四個 DOM 子命令不變。exec 本來不支援 is，維持原限制。

### Live in-flight acceptance

新增專用 localhost fixture，頁面只有自有 nonce 與會呼叫 confirm 的按鈕。啟動實際 click 子程序後，獨立 is dialog 必須在 3 秒內回 true，且 click 仍未結束；這證明未排在被阻塞的 JavaScript 後面。查詢本身不得 focus 或取消。測試的後續取消沿用期望 window ID／完整 nonce message 的具名 dismissal，最多一次，確認 click 的 handler 計數僅一次並驗證清理。

## Implementation Contract

CurrentWindowDialogProbe 以 Sendable WindowDialogStatus 回傳結果；provider context 與 AX node 留在 worker。所有時間屬同一個 800 ms deadline，worker busy 不排隊；GUI locked/unavailable、denied、缺目前身分、read error、截斷、identity changed、inactive/hidden-clear 一律 unknown。只有完整且前後身分一致、可見作用中的目前視窗能得到 clear。

pure provider 測試涵蓋三態、他窗隔離、前後身分改變、各未知原因與 busy/deadline。command 測試執行真實 run 並注入 probe 邊界，確認 stdout／stderr／exit code／JSON 與無 JS 呼叫。GUI 不可用時 live fixture 退出 77，不標 verified；實測 clear／pending／恢復與所有自有 window cleanup 後才完成。

## Risks / Trade-offs

- 不作用中或隱藏視窗的 absence 不足以排除 pending → unknown，不自動 activate 換取確定答案。
- AXMainWindow 不可用 → unknown，不沿用未有界 screenshot resolver 的 fallback。
- 使用者可在快照後切換分頁／觸發新 dialog → 文件明示即時觀察不預測未來，也不保證所有背景分頁無 pending。
- 共用 scanner 擴充可能影響 list/dismiss → 預設入口不變，跑既有 scanner、worker、global probe、listing 回歸。
