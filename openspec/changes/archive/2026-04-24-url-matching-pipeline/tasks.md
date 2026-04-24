## 1. 基礎型別：UrlMatcher sum-type vs flat enum case expansion

- [x] 1.1 實作 requirement `UrlMatcher sum-type encapsulates URL matching modes`：在 `SafariBridge.swift`（或新檔 `UrlMatcher.swift`）新增 sum-type enum，包含 `contains / exact / endsWith / regex` 四個 case，conform `Sendable + Equatable`，並實作純函式 `matches(_ url: String) -> Bool`，對應設計決策 `UrlMatcher sum-type vs flat enum case expansion`
- [x] 1.2 [P] 撰寫 `UrlMatcher.matches` 的 pure unit test 涵蓋四種 case 的成功、失敗與邊界情境（空字串 endsWith、Unicode URL、case sensitivity、unanchored regex 預設）
- [x] 1.3 重構 `TargetDocument` enum：將 `.urlContains(String)` 替換為 `.urlMatch(UrlMatcher)`；更新 `resolveDocumentReference` 對 `.urlMatch` 一律走 native-path enumeration（不再用 AppleScript `first document whose URL contains`）以落實 document reference resolution 對所有 matcher 的一致 fail-closed
- [x] 1.4 更新 `pickNativeTarget` / `pickFirstMatchFallback` 把原本 hardcode 的 substring 比對改成 `UrlMatcher.matches` 呼叫，落實設計決策 `Fail-closed policy 擴充範圍`：維持既有 fail-closed 行為並涵蓋 `unified urlContains fail-closed policy` 所有 matcher 變體

## 2. Bridge API: resolveToAppleScript 如何 propagate firstMatch

- [x] 2.1 依設計決策 `` `resolveToAppleScript` 如何 propagate `firstMatch` ``：`SafariBridge.resolveToAppleScript(_:firstMatch:warnWriter:)` 新增 default 參數（`firstMatch: Bool = false`、`warnWriter: ((String) -> Void)? = nil`），呼叫 `resolveNativeTarget` 時 forward 兩個參數，落實 requirement `First-match flag propagates through read-path resolver`
- [x] 2.2 所有 read-path bridge entry point（`doJavaScript`, `doJavaScriptLarge`, `getCurrentURL`, `getCurrentTitle`, 其他透過 `resolveToAppleScript` 的 static func）同步擴充 `firstMatch` / `warnWriter` default 參數並 forward
- [x] 2.3 [P] 撰寫 bridge plumbing integration test：用 stub `listAllWindows` 回傳 multi-match 情境，驗證 `resolveToAppleScript(..., firstMatch: true, warnWriter:)` 呼叫 fallback 並 invoke warnWriter

## 3. CLI flags 命名與互斥規則 + Commands wiring

- [x] 3.1 依設計決策 `CLI flag 命名與互斥規則` 在 `TargetOptions` 新增 `--url-exact`, `--url-endswith`, `--url-regex` 三個 flag，落實 requirement `Precise URL matching CLI flags`；`.resolve()` 根據哪個 flag 被供應回傳對應 `TargetDocument.urlMatch(UrlMatcher.…)` 搭配設計決策 `Regex flavor、anchoring、timeout`（`NSRegularExpression` 預設 options、unanchored、無 timeout）
- [x] 3.2 擴充 `TargetOptions.validate()` 的 target document selection via CLI flags 互斥規則：四個 URL flag 互斥、`--url-endswith ""` 拒絕、`--url-regex` compile 失敗立即 `ValidationError`
- [x] 3.3 依設計決策 `` Commands wiring：新增 `TargetOptions.resolveWithFirstMatch()` helper `` 在 `TargetOptions` 新增 helper 回傳 `(target, firstMatch, warnWriter)` tuple，預設 `warnWriter` 寫到 stderr
- [x] 3.4 所有 `@OptionGroup var target: TargetOptions` 的 command（`JSCommand`, `GetCommand`, `SnapshotCommand`, `StorageCommand`, `WaitCommand`, `ClickCommand`, `FillCommand`, `UploadCommand`, 以及其他掃到的 read-path commands）改用 `resolveWithFirstMatch()` 並傳給 bridge 呼叫，落實 first-match opt-in flag 在讀取路徑的端對端 plumbing
- [x] 3.5 Audit native-path commands（`close`, `screenshot`, `pdf`, `upload --native`）確認 `resolveNativeTarget` 的 `firstMatch` 參數有從 `TargetOptions` 正確傳入；依設計決策 `` 既有 `findExactMatch`（OpenCommand focus-existing）不動 `` 保留 `OpenCommand.findExactMatch` 的 exact-match 契約不擴張

## 4. Daemon protocol + 測試策略

- [x] 4.1 Audit `DaemonRouter.swift` / `DaemonClient.swift` 的序列化路徑，確認新增 `UrlMatcher` 結構為 additive field（若需要拆 follow-up change，在 tasks 中註記 deferred 並保持 CLI/bridge 層可用）
- [x] 4.2 [P] 補 command wiring test：針對 `JSCommand` 與 `GetCommand` 其中一個 command 撰寫 integration test，確認 `target.firstMatch` 有傳到 bridge（用 stubbed bridge 或 dependency injection）
- [x] 4.3 [P] 撰寫 CLI e2e smoke test：針對 `safari-browser js --url <shared-substring> --first-match` 與 `--url-endswith /play` 對測試用 Safari fixture 跑通，驗證 exit 0 + stderr warning 內容

## 5. 驗收與 issue 收尾

- [x] 5.1 Manual QA：用使用者 Plaud + edupsy lesson/auth/play tabs 情境實測 `--url-endswith` 與 `--first-match`，確認 hierarchical URL ambiguity 可乾淨鎖定
- [x] 5.2 更新 README / CHANGELOG 條目說明新 flags 與 first-match plumbing fix；若有 playbook skills（`safari-plaud-upload`, `safari-github-star`）可受益則加範例
- [x] 5.3 Close GitHub issues #33（plumbing bug）、#34（precise matching feature）；在 #35 追加 close-as-invalid comment 解釋 repro 實測不成立 + cross-reference 本 change 作為 hierarchical URL 解法
