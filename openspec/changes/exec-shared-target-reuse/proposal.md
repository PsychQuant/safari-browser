## Why

#170：daemon 的 in-process exec 對 `--url` 共用目標每一步都重新做一次完整的視窗／分頁列舉。6 步腳本在 41 個分頁時，main daemon 需要 5.2–5.9 秒，其中 6 次列舉是主要成本（每個 in-process AppleScript 都已命中編譯快取）。另外 daemon 的編譯快取沒有上限，會保留每一個不同的 source 直到 daemon 結束。

## What Changes

- URL pattern 共用目標（`--url`、`--url-exact`、`--url-endswith`、`--url-regex`）在第一個需要它的步驟解析，並在同一個 `exec.runScript` 請求內重用；每次重用前先以一個小型 AppleScript 驗證該分頁仍顯示 pattern 接受的網址，驗證失敗或出錯即重新解析，解析失敗不留下可重用的結果。其他目標形式（`--document`、`--tab`、`--window`、只有 `--profile`、無旗標）每一步都解析。
- 歧義與 `--first-match` 在每次解析時決定。這取代既有規格「exec 開始時解析一次」的措辭；規格改為明列重用的目標形式（封閉列表）。
- `--profile` 現在套用於解析與 `documents` 步驟（此前只解析、不傳入 bridge）。
- daemon 與 subprocess 路徑的結果差異改以封閉列表寫進規格，取代原本「逐位元組相同」的說法；差異本身另案追蹤（#220）。
- 無法 in-process 執行的步驟在解析之前就失敗。
- 編譯快取上限 256 個 source，超過時淘汰最久未使用者。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `script-exec`：共用目標的重用、驗證與重新解析；daemon 與 subprocess 路徑的結果差異；exec 層級 `--profile`。
- `persistent-daemon`：編譯快取有上限。

## Impact

- `InProcessStepDispatcher.swift`、`SafariBridge.swift`（`verifyResolvedTab`）、`PreCompiledScripts.swift` 及測試。
- subprocess 路徑（每步一個子行程）不變。
