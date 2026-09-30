## 1. 共用目標重用

- [x] 1.1 測試先失敗：一次解析、重用前驗證、導航／移動／關閉分頁與關閉視窗（含 daemon 錯誤形狀）、不快取 `--document`、無效步驟不解析、handler 每請求新 dispatcher
- [x] 1.2 實作 `SharedTargetResolution` 與 `verifyResolvedTab`；驗證出錯視為未驗證（Requirement: Shared target resolution）
- [x] 1.3 測試先失敗：四種 URL matcher 的重用與重新解析、解析失敗後不重用（歧義照報）、取消不重新解析、`documents` 步驟套用 `--profile`
- [x] 1.4 規格改為明寫兩條路徑不保證結果相同（已知差異另案 #220，不逐項列舉），只規範目標解析的差異與分頁集合變動時的額外分歧：多個分頁符合時，daemon 保留仍符合的已解析位置（Requirement: Daemon-routed execution when available；#220 之後改為「已知差異」清單，見 1.7）
- [x] 1.4b 收斂 `js` step 結果與 CLI 相同的範圍：base requirement 改為只承諾 scenario 名列的案例，其餘（錯誤通道、超過 1MB 的結果、`--file` / `--large` / `--output`）不保證，追蹤於 #220（Requirement: `js` step result semantics match the CLI）
- [x] 1.5 exec 層級與步驟層級 `--profile` 套用於解析、`documents` 步驟與 `--mark-tab` 的解析（Requirement: `--profile` on the daemon path applies to target resolution and to `documents`）
- [x] 1.6 測試：`--first-match` 與 `--profile` 搭配 URL pattern 仍重用；無可檢查依據的目標形式不做檢查；驗證腳本以 `considering case` 比較（含以真實 `osascript` 執行的語意測試）；hostile pattern 的跳脫以字面預期值斷言；預設編譯快取在 257 個 source 時淘汰最舊的

- [x] 1.7 #220：`InProcessStepDispatcher.runsInProcess` 的封閉形狀表，client 預檢與 dispatcher 共用；subprocess 的 `documents` 步驟補 `--json`；in-process `get text` 的 innerText 後備；`GetText` 遵守 `--first-match`；引用變數的步驟不送 daemon、`unsupportedArguments`、剩餘五項已知差異記入規格；pacing 的 Python 測試改用兩份腳本（Requirement: Daemon-routed execution when available）
- [x] 1.8 #220 R1：`ExecCommand.route` 與 `execute`（daemon 請求可注入）讓「送 daemon 或本機執行」的決定可測，`run()` 只負責讀腳本；差異測試以固定的 dialog observation 在同一個假 Safari 上比對兩條路徑的 `documents` 與 `get text`；子行程的實際 argv 由可注入的 runner 斷言；`documents` 的 `--json` 以與 `dispatch` 相同的方式切分指令；變異檢查（引用變數、缺值旗標、pacing／opt-in、`execute` 不用 `route`、daemon 答 nil 後不本機執行、`--json` 與 `invocation` 的接線、dispatcher 拒絕、step 層 `--first-match`、`GetText`、innerText 後備）全數被殺

## 2. 編譯快取上限

- [x] 2.1 測試先失敗：超過容量淘汰最久未使用者
- [x] 2.2 實作 LRU（256）（Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction）

## 3. 量測與文件

- [x] 3.1 同工作負載前後量測，記錄於 docs/performance.md
- [x] 3.2 CHANGELOG
