## Context

`SafariBridge` 目前所有 AppleScript 呼叫都 hard-code `current tab of front window`（~7 處）或 `front window`（2 處）。Safari 有兩個獨立的物件 collection：

- **window 層**：`window 1`, `window 2` ...，依 z-order 排序，`front window` 是最上層
- **document 層**：`document 1`, `document 2` ...，與 web view 緊密綁定，順序**不同於** window z-order

在一般單視窗情境這個區別不重要，但在以下三個情境會暴露問題（即 #17/#18/#21）：

1. **多視窗 z-order 歧義**（#17）：使用者看著 Plaud Web，但 Safari 剛好把 Claude OAuth window 當成 `front window`（例如因為使用者最近點過 OAuth 視窗），所有 CLI 操作打到錯誤頁面
2. **缺乏 override 機制**（#18）：即使知道目標 URL，也無法告訴 CLI「我要 plaud.ai 的 document」，只能切換 Safari 到前景
3. **Modal sheet 阻塞 window-level query**（#21）：實驗證據 — `osascript ... get URL of current tab of front window` 在 modal sheet 存在時無限卡住，但 `get URL of document 1` 立即回應。Safari 的 AppleScript dispatcher 對 window-scoped query 會經過 window UI layer（被 modal block），但 document-scoped query 直接存取 WebKit document 物件

這個 change 引入一個統一的 `TargetDocument` 抽象，讓所有 AppleScript generator 都接受 target 參數，同時把 read-only query 改為 document-scoped（作為 #21 的 primary fix）。

**Stakeholders**:
- 多視窗開發者（主要受益者）
- 既有腳本（必須維持 backward compat）
- CI / 非互動 automation（需要 deterministic target）
- 受 #21 影響的使用者（修完後 `get url` 不再卡住）

**Constraints**:
- `SafariBridge` 是所有 Commands 的共用基礎 — 30+ 個 command 都會受影響，改動必須 surgical
- Swift `AsyncParsableCommand` 的 global flag 需要通過 `ParsableCommand.configuration.subcommands` 或環境變數傳遞
- AppleScript `document whose URL contains "x"` 的 matching 是 case-sensitive — 需要文件化
- 向後相容：既有使用者不傳 flag 時行為必須完全一致

## Goals / Non-Goals

**Goals:**

- 統一的 `TargetDocument` 型別抽象，所有 AppleScript 呼叫透過它指定目標
- CLI 層提供 `--url` / `--tab` / `--window` / `--document` 四種 override 方式
- 解決 #21 — read-only query 用 document-scoped targeting 繞過 modal sheet 阻塞
- 完整向後相容：既有腳本無需改動
- 明確錯誤路徑：找不到 document 時列出所有可用的供使用者選
- 新增 `documents` subcommand 讓使用者列出 Safari 當前所有 documents（discovery tool）

**Non-Goals:**

- **不改變** `front window` 預設行為（backward compat）
- **不做** regex / glob matching（substring 足夠，且避免邊界情況）
- **不支援** 跨 Safari instance（TestFlight / beta 多 instance 情境）
- **不觸發** activate / window focus 切換（符合 non-interference 原則）
- **不自動 dismiss** modal sheets（document-scoped query 繞過即可）
- **不處理** tab focus 的副作用 — 純 targeting，不影響 Safari UI state
- **不改** AppleScript injection 機制（`escapedForAppleScript` 已足夠）

## Decisions

### 1. TargetDocument 型別設計

**Decision**: 用 Swift enum with associated values，四個 case：

```swift
enum TargetDocument: Sendable {
    case frontWindow                      // 預設 — 維持現狀
    case windowIndex(Int)                 // --window 2 (1-indexed, Safari convention)
    case urlContains(String)              // --url "plaud" (substring match)
    case documentIndex(Int)               // --document 1 (AppleScript collection order)
}
```

**Alternatives considered**:

- **Protocol-based（`protocol DocumentTarget`）**: 更 extensible 但過度工程，目前只有 4 種 case
- **Single string DSL（`"url:plaud"` / `"window:2"`）**: 看似簡潔但失去 type safety，parsing 錯誤延遲到 runtime
- **優先多個條件（`TargetDocument.any([.urlContains("plaud"), .windowIndex(2)])`）**: 增加歧義，YAGNI
- **Regex matching for URL**: 強大但 90% 的 use case 是 substring，regex 邊界情況（escaping、anchoring）會複雜化 UX

**Rationale**: enum with 4 variants 是最直接的 type-safe 表達，每個 case 對應一個 CLI flag，1:1 mapping 讓使用者心智模型簡單。Swift enum 的 exhaustive switching 保證 `resolveDocumentReference` 處理所有情況。

### 2. AppleScript Document Reference 生成

**Decision**: `resolveDocumentReference(_ target: TargetDocument) -> String` helper：

```swift
private static func resolveDocumentReference(_ target: TargetDocument) -> String {
    switch target {
    case .frontWindow:
        return "document 1"  // 見 decision 3
    case .windowIndex(let n):
        return "document of window \(n)"
    case .urlContains(let pattern):
        let escaped = pattern.escapedForAppleScript
        return #"first document whose URL contains "\#(escaped)""#
    case .documentIndex(let n):
        return "document \(n)"
    }
}
```

生成的 AppleScript reference 可以直接塞進 `tell application "Safari" to ... <ref> ...` 的位置，所有 getter（`get URL of`, `get source of`, ...）都能接受。

**Alternatives considered**:

- **生成完整 AppleScript 而非 reference string**: 每個 case 產一個完整 tell block — 但會讓每個 function 都要 switch target，代碼爆炸
- **使用 AppleEvent SDK 直接建 object specifier**: 避開字串生成 — 但需要引入 ScriptingBridge framework，大量 boilerplate，且 ScriptingBridge 對 Safari 的 type mapping 有陷阱
- **ref 只是資料結構，由 caller 負責 interpolation**: ref 作為 `Hashable struct` 帶 `applescriptValue` computed property — 這個等同於 helper function 但多一層封裝

**Rationale**: String-based reference 直接對應 Safari AppleScript 文件的寫法，維護成本低。`escapedForAppleScript` 已經處理好 `"` / `\` 的跳脫，安全性不變。

### 3. 預設行為：`document 1` vs `current tab of front window`

**Decision**: `.frontWindow` 解析成 `document 1`，**不是** `current tab of front window`。

**Rationale**:
- **繞過 #21 的 modal sheet 阻塞**：即使使用者沒有明確傳 target，預設用 document-scoped 存取也比 window-scoped 更 robust
- `document 1` 在單視窗情境下等價於 `current tab of front window`，所以**向後相容**
- 在多視窗情境下，`document 1` 與 `front window` 的順序可能不同 — 但這裡不是 regression，而是讓使用者**更容易發現**他們需要明確 target
- 使用者的 `osascript` workaround 已經證實 `document 1` 對 modal 免疫

**Risk**: `document 1` 的排序在某些 Safari 版本可能是 document 建立順序（非 z-order），與使用者預期的 "front window" 略有差異。
- **Mitigation**: `documents` subcommand 讓使用者立即看清楚目前的 document 排序
- **Mitigation**: 錯誤訊息（`documentNotFound`）在失敗時列出所有 documents 的 URL
- **Mitigation**: CHANGELOG 明確說明這個 subtle behavior change，建議多視窗使用者明確用 `--url`

**Alternatives considered**:

- **`.frontWindow` 解析成 `current tab of front window`**（維持現況）：但 #21 不會被修好，read-only query 還是會卡在 modal 上
- **條件 fallback**：先試 `current tab of front window`，fail 才 fallback 到 `document 1` — 但 window-scoped 的 fail 會 **hang forever**（#21 的核心問題），不是乾淨 error

### 4. CLI Flags 位置：global vs per-command

**Decision**: **Global flags** 在 top-level `SafariBrowser` command，用 `ParsableArguments` 共用到所有 subcommand。

```swift
struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "...") var url: String?
    @Option(name: .long, help: "...") var window: Int?
    @Option(name: .long, help: "...") var tab: Int?
    @Option(name: .long, help: "...") var document: Int?

    func validate() throws {
        let set = [url, window.map(String.init), tab.map(String.init), document.map(String.init)]
            .compactMap { $0 }
        if set.count > 1 {
            throw ValidationError("--url, --window, --tab, --document are mutually exclusive")
        }
    }

    func resolve() -> SafariBridge.TargetDocument {
        if let url = url { return .urlContains(url) }
        if let w = window { return .windowIndex(w) }
        if let t = tab { return .documentIndex(t) } // tab 和 document 在 Safari 中同義
        if let d = document { return .documentIndex(d) }
        return .frontWindow
    }
}
```

每個 command struct 加 `@OptionGroup var target: TargetOptions`，然後呼叫 `target.resolve()` 取得 `TargetDocument`。

**Alternatives considered**:

- **Per-command flags**: 每個 command 自己宣告 `--url` — DRY 失敗且部分 command 可能忘記
- **Environment variables**（`SAFARI_BROWSER_TARGET_URL=plaud`）: 對 CI 友善但失去 per-invocation override 能力
- **Config file** + env var: 過度工程

**Rationale**: `@OptionGroup` 是 ArgumentParser 官方推薦的 flag 共用 pattern，一次宣告到處用，`validate()` 統一檢查互斥。

**Note on `--tab` vs `--document`**: 在 Safari 的 AppleScript 模型裡，一個 document 對應一個 tab（tab 是 window 的 UI wrapper）。`--tab` 和 `--document` 在語意上是同一件事 — 保留 `--tab` 主要是 familiar terminology（對 browser automation 使用者直覺），但 internally map 到 `documentIndex`。`--window 2` 則是明確要選第 2 個 window 的 document（= window 2 的 current tab）。

### 5. Read-only 優先改用 document-scoped，write/keystroke 仍用 window-scoped

**Decision**:

- **read-only getters**（`getCurrentURL`, `getCurrentTitle`, `getCurrentText`, `getCurrentSource`, `doJavaScript`）：改用 `document X` reference — 繞過 modal block（#21 fix）
- **window-scoped 操作**（`openNewTab`, `switchToTab`, `upload` 的 keystroke 部分）：維持 `front window` / `window X` 語意 — 這些本來就需要 UI 互動，不能繞過

**Rationale**: 不是所有操作都能 document-scoped。Tab switching、keystroke、window 創建都需要 window UI layer。但 query 和 JS execution 是 document 層的，可以繞過。這個區分把 #21 fix 限制在正確的範圍。

**Risk**: 某些 command 可能處於「read 和 write 混合」狀態（例如 `snapshot --page` 先 query 再寫回）。這些要在 tasks 中逐一檢查。

### 6. Document discovery：`documents` subcommand

**Decision**: 新增 `safari-browser documents` subcommand 列出所有 Safari documents：

```
$ safari-browser documents
[1] https://web.plaud.ai/              — 個人 — Plaud Web
[2] https://platform.claude.com/oauth/ — 精準行銷 — Claude Platform
```

**Rationale**: 使用者需要 discovery tool 才能正確使用 `--url` / `--document`。否則第一次遇到 #17 時無法知道要傳什麼 pattern。這個 command 等於「列出所有可用 targets」，輸出格式與 `documentNotFound` error 訊息一致。

### 7. 錯誤路徑：documentNotFound with list

**Decision**: `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`:

```
Error: No document matching "plud" (typo for "plaud"?)
Available documents:
  [1] https://web.plaud.ai/
  [2] https://platform.claude.com/oauth/
```

**Rationale**: `documents` subcommand + 自動列出讓使用者無需額外呼叫就能修正錯誤。

## Risks / Trade-offs

- **Risk**: `document 1` 預設在多視窗情境可能不等於使用者視覺預期的 "front"
  **Mitigation**: 向後相容層面 single-window OK；多視窗 edge cases 靠 `documents` subcommand + `--url` 引導。CHANGELOG 明確標註 subtle change

- **Risk**: 30+ Commands 大範圍改動容易遺漏 target 透傳，造成部分 command 忽略 flag
  **Mitigation**: 列表式 task breakdown + grep-based validation step（tasks 會包含「grep `current tab of front window` 確認無殘留」）

- **Risk**: AppleScript `document whose URL contains` 是 case-sensitive，使用者可能困惑
  **Mitigation**: 文件化 + 考慮 `--url-ignore-case` flag（但 Non-Goal 已排除 regex，這算 feature creep，先不做）

- **Risk**: Safari 版本差異 — `document` collection 排序行為未被 Apple 明確文件化
  **Mitigation**: `documents` subcommand 讓使用者立即看到實際行為；不同版本的語意差異由 `--url` / `--window` 顯式 override

- **Risk**: 改 default 行為可能打破某些 edge case 腳本（雖然理論上 document 1 == current tab of front window）
  **Mitigation**: 在 CHANGELOG 標為 "subtle behavior change"，提供 opt-out（如果有強烈需求）— 或加 `--legacy-front-window-targeting` env var（先不加，觀察）

- **Risk**: 多個 issue 合併成一個 change 可能讓 review 困難
  **Mitigation**: Design doc 明確把 #17 / #18 / #21 的對應 decisions 分開列出；tasks 按 issue 分組

- **Trade-off**: substring matching vs regex — 選擇 substring 失去部分靈活性，但換來簡單可預測的 UX

- **Trade-off**: 維持 `--tab` 作為 alias 增加 CLI surface，但對 browser automation 使用者更直覺

## Migration Plan

這是一個新 capability 而非 destructive 改動，**沒有資料 migration**，但有使用者行為的 migration：

1. **Pre-release**: 實作 + 測試 + CHANGELOG 草稿
2. **Release**: CHANGELOG 包含 "Multi-document targeting" 區段，提供 quick-start examples
3. **Documentation**: README 新增 "Multi-window scenarios" 段落，CLAUDE.md / plugin 說明中提及 `--url` 推薦
4. **Backward compat window**: 單視窗使用者不需要改；多視窗使用者建議更新腳本到明確 target — 但舊腳本不會立刻壞（`.frontWindow` 預設繼續運作）
5. **Rollback**: 若發現嚴重 regression，revert commit 即可恢復原行為

## Open Questions

- **Q1**: `--tab` flag 要保留還是統一用 `--document`？`--tab` 對 browser automation 使用者更直覺，但 `--document` 更對應 AppleScript 模型。
  **Proposed**: 保留 `--tab` 作為 `--document` 的 alias（兩者等價）。

- **Q2**: `documents` subcommand 的輸出格式要 JSON 還是 text？
  **Proposed**: 預設 text（人讀），加 `--json` flag（script 用）— 沿用既有 convention（`snapshot --json`、`tabs --json`）。

- **Q3**: `--url` 的 matching 要 case-insensitive 預設嗎？
  **Proposed**: 維持 case-sensitive（符合 AppleScript 原生行為），不加額外 flag。如果使用者有需求再加 `--url-ignore-case`。

- **Q4**: 是否要 deprecate `listTabs` / `switchToTab` 以 `documents` + window navigation 取代？
  **Proposed**: **不 deprecate** — tab 是 UI concept，document 是 content concept，兩者並存。`tabs` 仍列出 front window 的 tabs，`documents` 列出所有 windows 的 documents。
