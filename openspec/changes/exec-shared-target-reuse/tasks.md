## 1. 共用目標重用

- [x] 1.1 測試先失敗：一次解析、重用前驗證、導航／移動／關閉分頁與關閉視窗（含 daemon 錯誤形狀）、不快取 `--document`、無效步驟不解析、handler 每請求新 dispatcher
- [x] 1.2 實作 `SharedTargetResolution` 與 `verifyResolvedTab`；驗證出錯視為未驗證（Requirement: Shared target resolution）
- [x] 1.3 測試先失敗：四種 URL matcher 的重用與重新解析、解析失敗後不重用（歧義照報）、取消不重新解析、`documents` 步驟套用 `--profile`
- [x] 1.4 規格改為明寫兩條路徑不保證結果相同（已知差異另案 #220，不逐項列舉），只規範目標解析的差異與分頁集合變動時的額外分歧：多個分頁符合時，daemon 保留仍符合的已解析位置（Requirement: Daemon-routed execution when available）
- [x] 1.5 exec 層級與步驟層級 `--profile` 套用於解析、`documents` 步驟與 `--mark-tab` 的解析（Requirement: `--profile` on the daemon path applies to target resolution and to `documents`）
- [x] 1.6 測試：`--first-match` 與 `--profile` 搭配 URL pattern 仍重用；無可檢查依據的目標形式不做檢查；驗證腳本以 `considering case` 比較（含以真實 `osascript` 執行的語意測試）；hostile pattern 的跳脫以字面預期值斷言；預設編譯快取在 257 個 source 時淘汰最舊的

## 2. 編譯快取上限

- [x] 2.1 測試先失敗：超過容量淘汰最久未使用者
- [x] 2.2 實作 LRU（256）（Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction）

## 3. 量測與文件

- [x] 3.1 同工作負載前後量測，記錄於 docs/performance.md
- [x] 3.2 CHANGELOG
