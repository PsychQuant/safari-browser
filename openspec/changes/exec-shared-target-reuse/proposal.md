## Why

#170：daemon 的 in-process exec 對 `--url` 共用目標每一步都重新做一次完整的視窗／分頁列舉。6 步腳本在 41 個分頁時，main daemon 需要 5.2–5.9 秒，其中 6 次列舉是主要成本（每個 in-process AppleScript 都已命中編譯快取）。另外 daemon 的編譯快取沒有上限，會保留每一個不同的 source 直到 daemon 結束。

## What Changes

- `--url` 共用目標在每個 `exec.runScript` 請求中解析一次；之後每一步重用前先以一個小型 AppleScript 驗證該分頁仍顯示 pattern 接受的網址，驗證失敗或出錯即重新解析。
- 歧義與 `--first-match` 在該次解析時決定，與既有規格「exec 開始時解析一次」一致。
- 無法 in-process 執行的步驟在解析之前就失敗。
- 編譯快取上限 256 個 source，超過時淘汰最久未使用者。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `script-exec`：共用目標的重用、驗證與重新解析。
- `persistent-daemon`：編譯快取有上限。

## Impact

- `InProcessStepDispatcher.swift`、`SafariBridge.swift`（`verifyResolvedTab`）、`PreCompiledScripts.swift` 及測試。
- stateless exec 不變。
