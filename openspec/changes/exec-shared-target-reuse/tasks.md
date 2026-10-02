## 1. 共用目標重用

- [x] 1.1 測試先失敗：一次解析、重用前驗證、導航／移動／關閉分頁與關閉視窗（含 daemon 錯誤形狀）、不快取 `--document`、無效步驟不解析、handler 每請求新 dispatcher
- [x] 1.2 實作 `SharedTargetResolution` 與 `verifyResolvedTab`；驗證出錯視為未驗證（Requirement: Shared target resolution）
- [x] 1.3 測試先失敗：四種 URL matcher 的重用與重新解析、解析失敗後不重用（歧義照報）、取消不重新解析、`documents` 步驟套用 `--profile`
- [x] 1.4 規格改為明寫兩條路徑不保證結果相同（已知差異另案 #220，不逐項列舉），只規範目標解析的差異與分頁集合變動時的額外分歧：多個分頁符合時，daemon 保留仍符合的已解析位置（Requirement: Daemon-routed execution when available）
- [x] 1.4b 收斂 `js` step 結果與 CLI 相同的範圍：base requirement 改為只承諾 scenario 名列的案例，其餘（錯誤通道、超過 1MB 的結果、`--file` / `--large` / `--output`）不保證，追蹤於 #220（Requirement: `js` step result semantics match the CLI）
- [x] 1.5 exec 層級與步驟層級 `--profile` 套用於解析、`documents` 步驟與 `--mark-tab` 的解析（Requirement: `--profile` on the daemon path applies to target resolution and to `documents`）
- [x] 1.6 測試：`--first-match` 與 `--profile` 搭配 URL pattern 仍重用；無可檢查依據的目標形式不做檢查；驗證腳本以 `considering case` 比較（含以真實 `osascript` 執行的語意測試）；hostile pattern 的跳脫以字面預期值斷言；預設編譯快取在 257 個 source 時淘汰最舊的

## 2. 編譯快取上限

- [x] 2.1 測試先失敗：超過容量淘汰最久未使用者
- [x] 2.2 實作 LRU（256）（Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction）

## 3. 量測與文件

- [x] 3.1 同工作負載前後量測，記錄於 docs/performance.md
- [x] 3.2 CHANGELOG

## 4. 重審（Sonnet 與 Codex）後的修正

- [x] 4.1 取消在整個請求內成立：直譯器每步之前檢查、步驟自帶 target 或 `documents` 也在開始前與解析後檢查、標記在包裝標題前檢查、步驟拋出的取消不記成步驟錯誤、`onError: continue` 不會越過（Requirement: Shared target resolution）。daemon 目前只在關閉或 listener 失效時取消請求，client 中途斷線不會取消（#242）
- [x] 4.2 編譯快取以 UTF-8 位元組為鍵，而非 Swift `String` 的標準等價比較（NFC 與 NFD 是兩個來源）（Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction）；共用目標的參數同樣以位元組為鍵，那是防禦性的（同一個 run 內 exec 層級參數不會改變），不是真實 run 會走的路徑
- [x] 4.3 測試：`--mark-tab` 的 profile 轉送涵蓋六個呼叫點、無可檢查依據的目標形式逐形式斷言結果與列舉次數、步驟自帶 target 旗標不繼承 exec 層級 `--profile`、被 `if:` 跳過與 `documents` 步驟不觸發解析
- [x] 4.4 規格：target 旗標為封閉列表且不含 `--first-match` 與 `--mark-tab`；「只在一種情形重用」改為必要條件；位置被接手的分頁不被偵測；step-level profile 與 marker 的範圍；daemon 模式的位置重用對 human-emulation「Daemon mode behavioural parity with stateless mode」與 document-targeting「Unified urlContains fail-closed policy」寫成明確例外
