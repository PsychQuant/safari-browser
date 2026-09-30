## Why

#168：`wait --js` 與 `wait --for-url` 每 500 ms 輪詢一次，且每次輪詢都重新解析目標。`--url` 目標每次輪詢就是一次完整的視窗／分頁列舉。它也破壞了指令本身的用途：等待「導航離開命名目標的那個網址」時，下一輪就找不到符合的分頁而失敗。

## What Changes

- 目標在第一次輪詢前解析一次，沿用 `js` 的錨定（#180）；第一次輪詢一定會執行，即使解析已用完 `--timeout`；解析時間計入 `--timeout` 但不會被它中斷。
- `wait --for-url` 依目標形式取得網址，封閉列表：預設目標與 `--window N` 讀指令開始時的目前分頁並檢查它仍是目前分頁；URL pattern 目標以解析當下的視窗網址清單為基準、依上一輪的網址追蹤該分頁；`--document N` 與 `--window N --tab-in-window M` 依位置讀取。
- 每一輪 `--for-url` 輪詢都做 blocking dialog probe。
- `wait --js` 沿用 `js` 的目標檢查；位置命名的分頁消失時回報 target-tab-changed 錯誤，而不是列出所有 profile 的所有分頁。
- `--timeout 0` 與負值現在會輪詢一次。
- `--timeout` 只界定第一次之後的輪詢何時可以開始，不界定指令花多久（#221）：解析與已開始的輪詢不被它中斷，指令可能晚於 `--timeout` 結束；輪詢之間的睡眠不再超過 deadline（`--timeout 200` 原本至少要 500 ms）。`--help` 說明這一點。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `wait`：輪詢的目標解析、追蹤與失敗行為。

## Impact

- `WaitCommand.swift`（`WaitURLAnchor`）、`SafariBridge.swift`（`resolveURLTargetWithWindowURLs`、`tabURLs`、`getCurrentURL` 的錨定分支）、`JSCommand.swift`（`anchoredFailure`）及測試。
- `wait --timeout` 的睡眠改為睡到 deadline 為止；其餘呼叫各自的上限不變。
- 預設目標與 `--window N` 的 wait 不再跟隨「目前分頁」：輪詢中途別的分頁成為目前分頁時，wait 會失敗。
