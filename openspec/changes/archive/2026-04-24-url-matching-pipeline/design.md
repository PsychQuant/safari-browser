## Context

本 change 處理 `safari-browser` URL targeting pipeline 的兩個問題——bundle `#33` (bug: `--first-match` 未 plumb 到 read-path) 與 `#34` (feature: 階層 URL 需 precise matching modes)。proposal.md 已記錄動機，這裡聚焦技術決策。

**Current architecture（相關範圍）**：

```
┌──────────────────────────────────────────────────────────────┐
│  CLI layer                                                   │
│  TargetOptions (--url, --window, --document, --first-match)  │
│    .resolve() -> TargetDocument                              │
└──────────────────────────────┬───────────────────────────────┘
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
      Read-path (docRef-based)     Native-path (windowIndex-based)
                 │                           │
                 ▼                           ▼
   SafariBridge.resolveToAppleScript   SafariBridge.resolveNativeTarget
   (+ doJavaScript, getCurrentURL,     (+ close, screenshot, pdf,
    getCurrentTitle, ...)               upload --native)
                 │                           │
                 └─────────────┬─────────────┘
                               ▼
                 pickNativeTarget + pickFirstMatchFallback
                 (in SafariBridge.swift:1402 / 1499)
```

**受影響檔案**（完整清單見 proposal.md Impact）：`TargetOptions.swift`、`SafariBridge.swift`、所有用 `@OptionGroup var target: TargetOptions` 的 10+ command、`DaemonRouter.swift` / `DaemonClient.swift`、Tests。

**既有契約 / 限制**：
- `TargetDocument` 是 `Sendable, Equatable` 的 value type
- `SafariBridge` API 為 static async function（非 protocol），signature 改動即為所有 caller 的 migration cost
- `document-targeting/spec.md` 的 `Unified urlContains fail-closed policy` 要求 multi-match 一律 fail-closed，`--first-match` 是唯一 opt-out
- `human-emulation/spec.md` 規定 `--first-match` 必須 emit stderr warning 列出所有 candidates
- 本 repo 禁止 mutable state / non-trivial state（見 `SafariBridge.swift:1453`：`Stateless — no caching between calls`）
- `non-interference` principle：resolver 行為不能搶焦點或出聲（已由 `resolveNativeTarget` 的 spatial gradient 保障）

## Goals / Non-Goals

**Goals:**

- 修復 `--first-match` 對 read-path 命令（`js`, `get`, `snapshot`, `wait`, `storage`, `click`, `fill`, `upload --js`）完全無效的 plumb-through bug
- 把 URL matching 邊界語意從「僅支援 substring」擴充到「contains / exact / endsWith / regex」四種模式，CLI flag 一次到位
- 把 matching mode variance 收斂在單一抽象（`UrlMatcher`）而非爆炸性 enum case，避免 `switch` 數量倍增
- 保持 `OpenCommand.findExactMatch` 現有 exact-match 契約不動（focus-existing 的直覺依賴於此）
- Bridge API 簽章改動集中在**一個 commit set**，不改兩次

**Non-Goals:**

- URL canonicalization（trailing slash / host case / percent-encoding 正規化）—`--url-exact` 是字串相等，任何 normalization 需求應改用 `--url-endswith` / `--url-regex` 表達
- `--regex-timeout` flag—YAGNI，風險低
- 重構 `OpenCommand.findExactMatch` 讓 `open` 接受 `UrlMatcher`—違反 human-emulation 直覺原則
- CLI flag 命名風格革命（`--url=exact:...` 等）—維持 flat flags
- Daemon protocol breaking change—只做 additive 擴充；若真的衝突則拆 follow-up change
- 清理既有 specs 中 `first-match` 的 wording（保持最小 delta）

## Decisions

### UrlMatcher sum-type vs flat enum case expansion

把 URL matching variance 抽成獨立 `UrlMatcher` sum-type，`TargetDocument.urlContains(String)` 變成 `TargetDocument.urlMatch(UrlMatcher)`。

```swift
enum UrlMatcher: Sendable, Equatable {
    case contains(String)
    case exact(String)
    case endsWith(String)
    case regex(NSRegularExpression)   // 預 compile 完成；建構 helper 處理失敗

    func matches(_ url: String) -> Bool { ... }  // 純函式，便於 unit test
}

enum TargetDocument: Sendable, Equatable {
    case frontWindow
    case windowIndex(Int)
    case urlMatch(UrlMatcher)           // was .urlContains(String)
    case documentIndex(Int)
    case windowTab(window: Int, tabInWindow: Int)
}
```

**Rationale**：`resolveDocumentReference`、`pickNativeTarget`、`findExactMatch`、`pickFirstMatchFallback` 都要對 URL 做比對。若 `TargetDocument` 直接展開 `urlExact` / `urlEndswith` / `urlRegex` 四個 top-level case，每一個 switch 要處理 5+ URL case，加總約 15+ 次 case 展開；用 `UrlMatcher` 子型別則所有 URL 比對收斂到一個 `UrlMatcher.matches(_:)` 純函式，外層 switch 只有一個 `.urlMatch` case。

**Alternatives considered**：
- **Flat enum expansion**（為每種 matching mode 新增 `TargetDocument` top-level case）：改動局部、無新抽象，但 switch 數量倍增，未來加 matching mode（例：`--url-startswith`、`--url-ignorecase`）時每次都要改動所有 switch
- **Matcher as `struct { kind: Kind; pattern: String }`**（非 enum，內部用 enum Kind）：compile-time safety 較弱（regex case 的 `NSRegularExpression` 不再由 type system 保證為已編譯 regex），不如 enum associated value 乾淨

### `resolveToAppleScript` 如何 propagate `firstMatch`

在 `resolveToAppleScript` 新增 default 參數 `firstMatch: Bool = false, warnWriter: ((String) -> Void)? = nil`，預設值維持 source-compat；所有 upstream API（`doJavaScript`, `doJavaScriptLarge`, `getCurrentURL`, `getCurrentTitle`, 其他 read-path entry point）同樣新增這兩個 default 參數。

**Rationale**：`firstMatch` 是 CLI 層的使用者 intent，本應從 command 手上一路傳到 resolver。既有 signature 用 default 參數擴充：
- ✓ 現有內部 caller（含未對 `--first-match` 有意識的測試）無 breakage
- ✓ `TargetOptions` + commands 層新增 `resolveWithFirstMatch()` helper，統一打包 `(target, firstMatch, warnWriter)` 傳遞
- ✓ 未來若需要更多 resolver 選項（例：`allowCrossSpace: Bool`），擴充同一個 default 參數 pattern 即可

**Alternatives considered**：
- **Context struct**（`struct ResolveOptions { var firstMatch: Bool; var warnWriter: ... }`）：可讀性好但引入新型別 + 所有 call site 要建構 struct；用 default 參數即可解決問題，YAGNI
- **Global mutable**（thread-local resolver option）：違反 immutability 原則、測試痛苦、非選項

### Commands wiring：新增 `TargetOptions.resolveWithFirstMatch()` helper

在 `TargetOptions` 新增 helper：

```swift
func resolveWithFirstMatch() -> (
    target: SafariBridge.TargetDocument,
    firstMatch: Bool,
    warnWriter: (String) -> Void
) {
    (
        resolve(),
        firstMatch,
        { msg in FileHandle.standardError.write(Data(msg.utf8)) }
    )
}
```

commands 從 `let documentTarget = target.resolve()` 改為 `let (documentTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()`，傳給 `SafariBridge.doJavaScript(..., target:, firstMatch:, warnWriter:)`。

**Rationale**：10+ commands 有重複的 stderr writer wiring，helper 收斂 boilerplate。未來若要 test 時替換 warnWriter（例：unit test capture 成 array），只需 override helper。

**Alternatives considered**：
- **讓 commands 自己寫 stderr writer**：重複且容易漏
- **`TargetOptions` 直接暴露 `firstMatch` property + static `defaultWarnWriter`**：caller 要手動組裝，與 `resolve()` 的「單一 call 得到 execute-ready 值」風格不一致

### CLI flag 命名與互斥規則

新增 flat flags：`--url-exact`, `--url-endswith`, `--url-regex`。互斥規則擴充：

| 條件 | 行為 |
|------|------|
| 四個 `--url*` flag 同時 > 1 個 | `ValidationError`「`--url, --url-exact, --url-endswith, --url-regex` 互斥」 |
| `--url*` + `--window` | 如現況：validation error（URL matching 與 window/document index 互斥） |
| `--url-regex <pattern>` 無法編譯 | `ValidationError` 列出 NSRegularExpression error |
| `--first-match` 配任何 `--url*` flag | 允許並 opt-in 多 match fallback |
| `--first-match` 單獨（無 `--url*`） | 允許 but no-op（不丟 error，維持現況相容性；未來可考慮 warning） |

**Rationale**：保持與 #34 reporter 提案一致、與既有 flat flag 風格（`--replace-tab`, `--new-tab` 等）一致、不引入 sub-flag 語法。

**Alternatives considered**：
- **`--url <pattern> --url-mode exact|endswith|regex`**：顯式 mode flag 組合；需要 mode 的 default 值處理（`--url foo` 單獨時 mode 是什麼？），且 4 種模式擴散成 2 個 flags 互動，validation 複雜
- **`--url=exact:pattern` / `--url=endswith:pattern`**：單一 flag + 前綴語法；與 Swift ArgumentParser 慣例不合且容易與合法 URL 內含冒號混淆

### Regex flavor、anchoring、timeout

`--url-regex <pattern>`：
- Flavor：Foundation `NSRegularExpression`（ICU flavor）
- Anchoring：**預設 unanchored**（如同 `NSRegularExpression.matches(in:options:range:)`）—使用者要 anchor 可自行加 `^...$`
- Case：預設 case-sensitive
- Timeout：無（見 Non-Goals）
- Compile 失敗：CLI validation error，不等到 resolver 才丟

**Rationale**：`NSRegularExpression` 是 Foundation 內建，無新依賴；unanchored 與 `.contains` 直覺一致（使用者可自行 anchor 變 full-string match，但預設不 over-enforce）。

**Alternatives considered**：
- **SwiftRegex (`Regex<>`)**：type-safe，但需要 Swift 5.7+ runtime 且 Safari 相容 macOS baseline 未統一；`NSRegularExpression` 範圍最穩
- **預設 anchored**：使用者直覺中 regex 是「部分匹配」，強制 anchor 會讓 `--url-regex plaud` 失敗但 `--url plaud` 成功，行為不一致

### Fail-closed policy 擴充範圍

現有 `document-targeting/spec.md` 的 `Unified urlContains fail-closed policy` 只提 `urlContains`。延伸到：

- `urlMatch(.contains(_))` — 不變（現有行為）
- `urlMatch(.exact(_))` — 多 match 不可能出現（exact equality），policy 無影響但仍 fail-closed 作為 defense-in-depth
- `urlMatch(.endsWith(_))` — 多 match 可能（例：兩個 tab 都以 `/play` 結尾）→ fail-closed，`--first-match` opt-out
- `urlMatch(.regex(_))` — 多 match 可能 → fail-closed，`--first-match` opt-out

**Rationale**：使用者 mental model 要一致——「精確的 matcher 本來就該唯一，若多 match 代表 pattern 不夠精確」。`--first-match` 作為統一 opt-out 不分 matcher type。

### 既有 `findExactMatch`（OpenCommand focus-existing）不動

保留 `SafariBridge.findExactMatch(url:in:)` 現有 `tab.url == url` 比對，`OpenCommand` 不接受新的 `--url-*` flags。

**Rationale**：
- `findExactMatch` 的契約是「`open` 不 focus 不相關 prefix」（line 143 comment），放寬會讓 `open "/page/A"` focus 到 `/page/A/subpath` tab，違反使用者直覺
- #35 實測 repro 不成立，focus-existing 運作正常；本 change 不擴充其 scope
- Reporter 的真實需求（hierarchical URL disambiguation）由 `--url-endswith` 在 read-path 解決，不需要擴張 `open` 的語意

**Alternatives considered**：
- **讓 `open` 接受 `--url-exact` / `--url-endswith` 作為 focus-existing selector**：模糊了「`open` 是導航」與「targeting flag 是選擇目標」兩個正交 concept；先不做

### 測試策略

| 層級 | 目標 |
|------|------|
| Pure unit test | `UrlMatcher.matches(_:)` 四種 case 的精確 / 邊界行為（空 pattern、Unicode、長 URL） |
| Pure unit test | `TargetOptions.validate()` 互斥規則（四 URL flag 互斥、regex compile 失敗、與 `--window` 互斥） |
| Plumbing integration test | 模擬 `listAllWindows` 回傳 stub，驗證 `resolveToAppleScript(target:firstMatch:warnWriter:)` 在 `--first-match` 時 fallback 到 `pickFirstMatchFallback` 並呼叫 warnWriter |
| Command wiring test | `JSCommand` / `GetCommand` 其中 1-2 個 command 的 integration test：確認 `target.firstMatch` 有傳到 bridge（用 dependency injection 或 stub bridge） |
| CLI e2e smoke test | 實際 run `safari-browser js --url <shared-substring> --first-match 'document.title'` 對測試 Safari fixture，檢查 exit 0 + stderr warning |

## Risks / Trade-offs

- **Bridge API signature 改動影響所有 caller** → 用 default 參數擴充（`firstMatch: Bool = false, warnWriter: ((String) -> Void)? = nil`），既有 caller source-compat；新 caller opt-in 傳值
- **`TargetDocument.urlContains` 移除是 internal breaking change** → 本 repo 內 grep 全部 call site 一次性更新；`urlContains` 沒有 public API 承諾（`SafariBridge` 是 static API，非 library），migration cost 集中且可控
- **`UrlMatcher` 新抽象引入 YAGNI 風險** → 本 change 有明確 4 種 matcher 已確定，抽象有立即價值；若只有 1-2 種則傾向 flat expansion，但 4 種已跨過抽象 break-even
- **Regex 無 timeout 可能被 pathological pattern 卡住** → Safari tab URL 長度有限（Safari 實務上幾 KB 上限），ReDoS 風險極低；`NSRegularExpression` 本身對極端情況會 throw，不會無限 loop
- **Daemon protocol 需傳遞 matcher 結構** → MessagePack / JSON additive field 擴充（若現行已用字串 pattern，加 `matcherKind` enum 欄位即可）；若不幸需 breaking change，design 建議：本 change 先 ship CLI + bridge 層，daemon 支援列為 follow-up change
- **`--first-match` 單獨（無 `--url*`）行為模糊** → 本 change 保持 no-op（不丟 error），避免 scope creep；留 `## Open Questions` 追蹤
- **既存 test suite 中 `.urlContains(...)` 的 test 字面量** → grep & replace 為 `.urlMatch(.contains(...))`，純機械轉換

## Migration Plan

本 change 不涉及 runtime 資料遷移（純 code-level），但 internal API 改動需集中處理：

1. 先新增 `UrlMatcher` type 與 `TargetDocument.urlMatch` case，同時保留 `TargetDocument.urlContains` deprecated case 並轉發
2. 逐一遷移 call site 從 `.urlContains(x)` → `.urlMatch(.contains(x))`
3. 所有 call site 遷移完後移除 `.urlContains` deprecated case（同一個 PR 內或 follow-up commit）
4. CLI flag 新增（`--url-exact` / `--url-endswith` / `--url-regex`）可與 (1)-(3) 平行進行
5. `--first-match` plumbing fix 最後處理（依賴 `TargetOptions.resolveWithFirstMatch` helper，helper 又依賴 (1) 的新 bridge signature）
6. Rollback：本 change 以一個 change set 為單位 revert；若只 revert plumbing 部分（保留 `UrlMatcher`），行為回退到 current buggy state

## Open Questions

- **`--first-match` 單獨使用（無 `--url*`）應該 error 還是 no-op？**—本 change 預設 no-op（相容現況），留作未來決議
- **Daemon protocol 的 `UrlMatcher` 編碼格式**—附加欄位具體 schema（string + kind enum vs. discriminated union）在 daemon 實作時決定，design 暫不綁死
- **`--url-regex` 是否 emit compile-time stderr warning 若 pattern 過度寬鬆（例：`.*`）?**—目前不做，但若實務踩坑可在後續 change 加
- **`--url-endswith` 的空字串語意**（`--url-endswith ""` 應該 match 所有還是 error？）—傾向 validation error（空後綴表達不出意圖），寫入 spec scenarios 定義
