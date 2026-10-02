## Why

#170：daemon 的 in-process exec 對 `--url` 共用目標每一步都重新做一次完整的視窗／分頁列舉。6 步腳本在 41 個分頁時，main daemon 需要 5.2–5.9 秒，其中 6 次列舉推定是主要成本（由改動前後的總時間與單次暖機追蹤的 span 次數推論，沒有逐段計時；該次暖機追蹤中每個 in-process AppleScript 都已命中編譯快取）。另外 daemon 的編譯快取沒有上限，會保留每一個不同的 source 直到 daemon 結束。

## What Changes

- URL pattern 共用目標（`--url`、`--url-exact`、`--url-endswith`、`--url-regex`）在第一個需要它的步驟解析，並在同一個 `exec.runScript` 請求內重用；每次重用前先以一個小型 AppleScript 驗證該分頁仍顯示 pattern 接受的網址，驗證失敗或出錯即重新解析，解析失敗不留下可重用的結果。其他目標形式（`--document`、`--tab`、`--window`、`--window --tab-in-window`、只有 `--profile`、無旗標）每一步都解析。
- 歧義與 `--first-match` 在每次解析時決定。這取代既有規格「exec 開始時解析一次」的措辭；規格改為明列重用的目標形式（封閉列表）。
- `--profile` 現在套用於解析、`documents` 步驟與 `--mark-tab` 的解析（此前只解析、不傳入 bridge）：exec 層級的 `--profile` 限制 exec 層級目標、`documents` 與標記；步驟層級的 `--profile` 只限制該步驟自己的解析。自帶 target 旗標的步驟只用自己的旗標，不繼承 exec 層級的 `--profile`（兩條路徑一致）。
- 規格不再宣稱 daemon 與 subprocess 路徑的結果逐位元組相同（實際上並非如此），改為明寫不保證，並只規範目標解析的差異；已知的結果差異另案追蹤（#220），規格不逐項列舉。
- 無法 in-process 執行的步驟在解析之前就失敗。
- 編譯快取上限 256 個 source，超過時淘汰最久未使用者。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `script-exec`：共用目標的重用、驗證與重新解析；取消在整個請求內成立；daemon 與 subprocess 路徑目標解析的差異（不保證結果相同）；`js` step 結果與 CLI 相同的範圍；daemon 路徑的 `--profile`。
- `persistent-daemon`：編譯快取有上限，並以來源的 UTF-8 位元組為鍵。
- `human-emulation`：「Daemon mode behavioural parity with stateless mode」為單一 exec 請求內的位置重用寫明例外。
- `document-targeting`：「Unified urlContains fail-closed policy」寫明重用不是一次解析、不重新計數符合的分頁。

## Impact

- `InProcessStepDispatcher.swift`、`SafariBridge.swift`（`verifyResolvedTab`）、`DaemonDispatch.swift`（`--mark-tab` 的解析帶 profile）、`PreCompiledScripts.swift` 及測試。
- subprocess 路徑（每步一個子行程）不變。
