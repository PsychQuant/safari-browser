## Why

URL targeting pipeline 目前有兩個相連的問題：

1. **Plumb-through gap（#33）**：`--first-match` flag 在 CLI 層被正確 parse（`TargetOptions.firstMatch`）、在 bridge 層有完整 fallback 實作（`SafariBridge.resolveNativeTarget(from:firstMatch:warnWriter:)`），但中間的 `resolveToAppleScript(_:)` 把 `firstMatch` 參數**硬編成 `false`**，從未讓 CLI 的意圖穿到 resolver。所有 read-path 命令（`js`, `get url/title`, `snapshot`, `storage`, `wait`, `click`, `fill`, `upload --js`）都受影響——使用者照著 error message 的建議加 `--first-match` 得到同一個 error，工作流完全 broken。
2. **Substring-only matching 遇到階層 URL 歧義（#34）**：`TargetDocument.urlContains(String)` 只做 substring 比對。當 URL A 是 URL B 的嚴格前綴時（例如 `/lesson/xxx` 與 `/lesson/xxx/video/yyy/play`），任何唯一識別 A 的 substring 都會同時命中 B。階層式 URL scheme 在本 repo 常見（教學平台、Plaud、GitHub 等），使用者只能退回 `documents` + `--window N --tab-in-window M` 兩步走 workaround。

分開修的代價：`resolveToAppleScript` signature 要被改兩次（先 plumb `firstMatch`，再加 matching mode），commands 的 wiring 要掃兩輪，`document-targeting` spec 要 RFC 兩次。bundle 成一個 change 收斂到一次 API 改動與一輪 spec 更新。

同步處理 #35（open 複製 tab 的回報）：實測確認 reporter 的 literal repro 不成立——`focusExistingTab` 已 land 於 commit `68a64bc`（2026-04-18）且運作正常（用 `https://web.plaud.ai/` 測過：呼叫 `open` 後 tab 數不變）。Reporter 真實痛點其實是 #34 的 hierarchical URL 歧義，本 change 一併解決。#35 將 close as invalid 並 cross-link 到本 change。

## What Changes

- **BREAKING (internal)**: `TargetDocument.urlContains(String)` → `TargetDocument.urlMatch(UrlMatcher)`，新增 `UrlMatcher` sum-type（`contains / exact / endsWith / regex`）。`urlContains` 不再是 top-level case——`--url <substring>` CLI flag 映射到 `.urlMatch(.contains(...))`。所有 internal callers 需更新。
- **New CLI flags** (在 `TargetOptions`):
  - `--url-exact <url>`：完全相等比對（大小寫敏感、不做 URL canonicalization）
  - `--url-endswith <suffix>`：suffix 比對
  - `--url-regex <pattern>`：regex 比對（Foundation `NSRegularExpression`，預設 unanchored，無 timeout）
  - 四個 URL flags（`--url`, `--url-exact`, `--url-endswith`, `--url-regex`）互斥
- **Plumb `firstMatch` through read-path pipeline**:
  - `SafariBridge.resolveToAppleScript(_:)` 新增 `firstMatch: Bool = false, warnWriter: ((String) -> Void)? = nil` 參數
  - Read-path API（`doJavaScript`, `doJavaScriptLarge`, `getCurrentURL`, `getCurrentTitle`, 以及其他透過 `resolveToAppleScript` 的 entry point）同步加上 `firstMatch` / `warnWriter` 參數
  - Native-path API（`close`, `screenshot`, `pdf`, `upload --native`）audit `resolveNativeTarget` 呼叫點，確認 `firstMatch` 有傳入
  - 所有用 `@OptionGroup var target: TargetOptions` 的 commands 讀 `target.firstMatch` 並傳給 bridge（預期引入 `TargetOptions.resolveWithFirstMatch()` helper 收斂呼叫樣式）
- **Fail-closed policy 擴充**：現行 `Unified urlContains fail-closed policy`（`document-targeting` spec）延伸涵蓋所有 `UrlMatcher` case——多 match 時一律 `ambiguousWindowMatch`，`--first-match` 是唯一 opt-out
- **Close #35 as invalid**：在 #35 留 repro test 結果 + cross-reference 本 change，回 reporter hierarchical URL 需求由 `--url-endswith` 解決
- **Regression tests**：新增 unit test 涵蓋 `UrlMatcher` 四種 case 的純函式比對、plumbing integration test 涵蓋 `js/get/snapshot/wait --url ... --first-match` 多 match 場景

## Non-Goals (optional)

- **URL canonicalization（不做）**：`--url-exact` 是字串相等比對，**不**做 trailing slash / percent-encoding / host case 正規化。若 reporter 的 URL 與 Safari 儲存形式不一致，應該用 `--url-endswith` 或 `--url-regex` 表達，而不是讓 exact 隱式做 normalization——否則 focus-existing 契約（line 143 comment "so `open` does not focus unrelated pages that share a prefix"）會變模糊
- **Regex timeout option（不做）**：`--regex-timeout` YAGNI。Safari tab URL 長度有限、使用者自己寫 pattern，catastrophic backtracking 風險低。若未來真的出事再加
- **Generalize `OpenCommand.findExactMatch` to UrlMatcher（不做）**：`open` 的 focus-existing 維持 exact-match 契約。放寬會讓「open `/page/A` focus 了 `/page/A/subpath`」這類驚訝行為變成合法——違反 human-emulation 的直覺優先原則
- **CLI flag 名稱風格重構（不做）**：維持 flat flag 命名（`--url-exact` 而非 `--url=exact:...`），reporter 在 #34 已提出此風格，與既有 `--first-match` / `--replace-tab` 一致
- **Daemon protocol version bump（暫不做）**：`channel-server` 若能透過 additive field 傳遞新 matcher 結構就 in-place 擴充；若需要 breaking protocol change 則拆成 follow-up change

## Capabilities

### New Capabilities

(none — 本 change 只重構既有 `document-targeting` capability)

### Modified Capabilities

- `document-targeting`: 取代 `TargetDocument.urlContains(String)` top-level case 為 `.urlMatch(UrlMatcher)`；新增 `--url-exact` / `--url-endswith` / `--url-regex` CLI flag；擴充互斥規則；擴充 fail-closed policy 至所有 `UrlMatcher` case；明確化 `--first-match` 必須透過 `resolveToAppleScript` 正確 plumb 到 `resolveNativeTarget` 的 requirement（plumbing completeness）

## Impact

**Affected specs**:
- `openspec/specs/document-targeting/spec.md`（主要 delta：requirements 改寫 / scenarios 新增 / fail-closed policy 擴充）
- `openspec/specs/human-emulation/spec.md`（審視 `--first-match` 相關段落是否需補充 scenario，預期僅小幅 delta 或無）
- `openspec/specs/navigation/spec.md`（審視 `open` 對 `--first-match` / 新 matching flags 的 scenario，預期僅 scenario 新增）

**Affected code**:
- `Sources/SafariBrowser/Commands/TargetOptions.swift`（新 flags、新 validate 規則、可能的 resolver helper）
- `Sources/SafariBrowser/SafariBridge.swift`（`TargetDocument` enum 重構、`UrlMatcher` 新類型、`resolveDocumentReference`、`resolveToAppleScript`、`pickNativeTarget`、`resolveNativeTarget`、`doJavaScript*`、`getCurrentURL`、`getCurrentTitle`、其他 read-path entry points）
- `Sources/SafariBrowser/Commands/*.swift`（所有用 `@OptionGroup var target: TargetOptions` 的 command 需 wiring——至少 10+ 檔：`JSCommand`, `GetCommand`, `SnapshotCommand`, `StorageCommand`, `WaitCommand`, `ClickCommand`, `FillCommand`, `UploadCommand`, `CloseCommand`, `ScreenshotCommand`, `PdfCommand`, ...）
- `Sources/SafariBrowser/Daemon/DaemonRouter.swift`, `DaemonClient.swift`（確認 error 透傳與 matcher 序列化）
- `Tests/SafariBrowserTests/`（`UrlMatcher` 純函式 unit test、`resolveToAppleScript` plumbing test、CLI e2e test for 新 flags）

**Affected users / workflows**:
- Playbook skills（`safari-plaud-upload`, `safari-github-star` 等）階層 URL 鎖定變乾淨
- 外部自動化腳本使用 `--first-match` 的能恢復原預期行為
- GitHub issues #33（bug）+ #34（feature）→ fix；#35 → close as invalid
