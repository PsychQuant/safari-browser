## 1. 共用目標重用

- [x] 1.1 測試先失敗：一次解析、重用前驗證、導航／移動／關閉分頁與關閉視窗（含 daemon 錯誤形狀）、不快取 `--document`、無效步驟不解析、handler 每請求新 dispatcher
- [x] 1.2 實作 `SharedTargetResolution` 與 `verifyResolvedTab`；驗證出錯視為未驗證（Requirement: Shared target resolution）
- [x] 1.3 測試先失敗：四種 URL matcher 的重用與重新解析、解析失敗後不重用（歧義照報）、取消不重新解析、`documents` 步驟套用 `--profile`
- [x] 1.4 記錄 daemon 與 subprocess 路徑的結果差異為封閉列表（五項，另案 #220），以及分頁集合變動時唯一的額外差異：多個分頁符合時，daemon 保留仍符合的已解析位置（Requirement: Daemon-routed execution when available）
- [x] 1.5 exec 層級 `--profile` 套用於解析與 `documents` 步驟（Requirement: Exec-level `--profile` applies to target resolution and to `documents`）
- [x] 1.6 測試：`--first-match` 與 `--profile` 搭配 URL pattern 仍重用；無可檢查依據的目標形式不做檢查；驗證腳本以 `considering case` 比較；hostile pattern 的跳脫以字面預期值斷言

## 2. 編譯快取上限

- [x] 2.1 測試先失敗：超過容量淘汰最久未使用者
- [x] 2.2 實作 LRU（256）（Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction）

## 3. 量測與文件

- [x] 3.1 同工作負載前後量測，記錄於 docs/performance.md
- [x] 3.2 CHANGELOG
