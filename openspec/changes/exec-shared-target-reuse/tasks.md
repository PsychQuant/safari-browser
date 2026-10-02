## 1. 共用目標重用

- [x] 1.1 測試先失敗：一次解析、重用前驗證、導航／移動／關閉分頁與關閉視窗（含 daemon 錯誤形狀）、不快取 `--document`、無效步驟不解析、handler 每請求新 dispatcher
- [x] 1.2 實作 `SharedTargetResolution` 與 `verifyResolvedTab`；驗證出錯視為未驗證（Requirement: Shared target resolution）
- [x] 1.3 測試先失敗：四種 URL matcher 的重用與重新解析、解析失敗後不重用（歧義照報）、取消不重新解析、`documents` 步驟套用 `--profile`
- [x] 1.4 規格改為明寫兩條路徑不保證結果相同（已知差異另案 #220，不逐項列舉），只規範目標解析的差異與分頁集合變動時的額外分歧：多個分頁符合時，daemon 保留仍符合的已解析位置（Requirement: Daemon-routed execution when available；#220 之後改為「已知差異」清單，見 1.7）
- [x] 1.4b 收斂 `js` step 結果與 CLI 相同的範圍：base requirement 改為只承諾 scenario 名列的案例，其餘（錯誤通道、超過 1MB 的結果、`--file` / `--large` / `--output`）不保證，#220 之後 `--file` / `--large` / `--output` 讓整份腳本走 subprocess（由 CLI 自己處理），錯誤通道與大結果的差異記為已知差異（Requirement: `js` step result semantics match the CLI）
- [x] 1.5 exec 層級與步驟層級 `--profile` 套用於解析、`documents` 步驟與 `--mark-tab` 的解析（Requirement: `--profile` on the daemon path applies to target resolution and to `documents`）
- [x] 1.6 測試：`--first-match` 與 `--profile` 搭配 URL pattern 仍重用；無可檢查依據的目標形式不做檢查；驗證腳本以 `considering case` 比較（含以真實 `osascript` 執行的語意測試）；hostile pattern 的跳脫以字面預期值斷言；預設編譯快取在 257 個 source 時淘汰最舊的

- [x] 1.7 #220：`InProcessStepDispatcher.runsInProcess` 的封閉形狀表，client 預檢與 dispatcher 共用；subprocess 的 `documents` 步驟補 `--json`；in-process `get text` 的 innerText 後備；`GetText` 遵守 `--first-match`；以變數開頭的參數不送 daemon（變數在中間不影響形狀）、`unsupportedArguments`、剩餘五項已知差異記入規格；pacing 的 Python 測試改用兩份腳本（Requirement: Daemon-routed execution when available）
- [x] 1.8 #220 R1：`ExecCommand.route` 與 `execute`（daemon 請求可注入）讓「送 daemon 或本機執行」的決定可測，`run()` 只負責讀腳本；差異測試以固定的 dialog observation 在同一個假 Safari 上比對兩條路徑的 `documents` 與 `get text`；子行程的實際 argv 由可注入的 runner 斷言；`documents` 的 `--json` 以與 `dispatch` 相同的方式切分指令；變異檢查（引用變數、缺值旗標、pacing／opt-in、`execute` 不用 `route`、daemon 答 nil 後不本機執行、`--json` 與 `invocation` 的接線、dispatcher 拒絕、step 層 `--first-match`、`GetText`、innerText 後備）全數被殺
- [x] 1.9 #220 R2：`hasReference` 改為 `beginsWithReference`，與 `substitute` 共用同一個掃描器 `VariableStore.reference(in:at:)`（differential 測試）；目標旗標的值不得以 `-` 開頭；`js` 沒有程式碼也走 `unsupportedArguments`；`--mark-tab` 要了卻走逐步路徑時在 stderr 說明；變數的文法在 `Variable capture and substitution` 寫明（與程式碼一致：字母或 `_` 起頭）；pacing 與 daemon opt-in 的 `run()` 接線由 Python 測試守住

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

## 5. 更多指令在 daemon 內執行（#219）

- [x] 5.1 `click`、`fill`、`type`、`press` 與 `storage` 子指令是「一次 JavaScript 呼叫」：腳本與結果處理抽成 CLI 與 dispatcher 共用的函式（`perform`、`StorageScripts`），封閉的參數形狀列表擴充；`wait` 與 `snapshot` 不納入，含它們的腳本仍整份走 subprocess（Requirement: Daemon-routed execution when available）
- [x] 5.2 測試：形狀表（接受與拒絕）、與 CLI 指令送出相同的 JavaScript／回傳相同的值／以相同方式失敗、共用 `--url` 目標一次解析、整份腳本的路由
- [x] 5.3 量測：混合腳本 before／after（見 docs/performance.md；Safari 只有 1 個分頁，量不到列舉成本）
- [x] 5.4 審查發現並修正：`press` 空字串／只有 `+` 的 key 與過大的 `@e` ref 以 force-unwrap 崩潰（改為錯誤／不存在的 ref；形狀判斷把無名 key 留給子行程）；daemon 日誌以明文記下 `exec.runScript` 的步驟參數（Requirement: Daemon log redaction：步驟的 `args` 與 `if` 一律遮蔽）；測試補上目標／profile／`--first-match`／步驟層目標覆蓋、獨立的跳脫預期值、`var`／`onError`、路由
- [x] 5.5 第三輪審查：日誌遮蔽對格式不對的請求也成立（`steps` 不是物件陣列、`args` 不是陣列、數字、拼錯的 key）；`exec.runScript` 的結果只留步驟編號、狀態、`var`、錯誤碼，`value` 與 `error.message` 以大小取代（Requirement: Daemon log redaction）；`press` 的 key 在任何位置帶 `$變數` 就不送 daemon、無名 key 留給 CLI；共用的跳脫函式改為 literal（`'`、`\\`、`"` 後接組合字元原本不被跳脫）；規格的封閉形狀列表補上 `press` 的有名 key 規則

