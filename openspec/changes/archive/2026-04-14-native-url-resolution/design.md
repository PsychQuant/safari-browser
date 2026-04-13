## Context

#23 為 safari-browser 引入 multi-document targeting：`--url` / `--window` / `--tab` / `--document` 四個全域 flag，透過 `@OptionGroup var target: TargetOptions` 掛載到所有 subcommand。但 #23 R5 刻意把 window-only primitives（`close`、`screenshot` AX mode、`pdf`、`upload --native`、`upload --allow-hid`）排除在 document-scoped targeting 之外，改用受限的 `WindowOnlyTargetOptions` type，理由是這些命令底層走 System Events keystrokes 或 `CGWindowListCopyWindowInfo`，**沒有 document-scoped primitive**。

當時的 trade-off 是：
- **選 WindowOnly**：parse-time 拒絕 `--url / --tab / --document`，使用者立刻看到錯誤
- **未選 resolver**：怕「URL resolve 到 window index」這個 resolver 還沒實作，先把 CLI surface 限制住

三週後 #24 出現：`upload --js` 因 V8 O(n²) 字串 concat 撐爆 Safari，被迫在 10 MB 硬上限後強制大檔走 `--native`。這讓「native path 無法 URL target」從「不太方便」升級成「直接斷路 AI agent autonomy」。che-local-plugins plaud-transcriber v1.8.2 被手動 rewrite 成「請手動切到 Plaud tab」就是這個斷路的第一個可觀測症狀。

現狀下，要讓 `upload --native` 打到 Plaud 而不靠使用者人工切 tab，唯一的 workaround 是：

```bash
WIN=$(safari-browser documents | grep -n plaud | cut -d: -f1)
safari-browser upload --native "input[type=file]" "$f" --window $WIN
```

問題：shell pipeline race condition、`documents` 格式變動就炸、AI agent 不友善。本 change 把這個 resolver 下沉到 Swift 層。

## Goals / Non-Goals

**Goals:**

- 所有 window-only primitives 接受完整 `TargetOptions`（`--url` / `--window` / `--tab` / `--document`），與 #23 的 document-scoped path 語義完全對稱
- URL → window index 的 resolve 發生在 Swift process 內部，與後續的 raise / keystroke 在同一個 AppleScript session，消除 shell workaround 的 race condition
- 保留 #23 R5 的 safety net：keystroke 仍然只能打 front window（physical constraint 不變），但 resolver 先把對應 window 帶到前面
- Screenshot AX path 保留非破壞性：有 Accessibility 權限時，`screenshot --url plaud` 讀 hidden window bounds，**不** raise
- 廢除 `WindowOnlyTargetOptions` 這個過渡 type，讓 CLI surface 單一 source of truth

**Non-Goals:**

- **不**引入本機 HTTP server 或任何繞過 browser 上傳路徑的 novel mechanism — #24 discussion 已排除，違反 non-interference spec 的「mimic human behavior」principle
- **不**實作跨 Safari instance disambiguation（Safari Technology Preview 等）— out of scope，需要時另開 issue
- **不**新增 `--no-raise` opt-out flag — raise 是 keystroke path 的 physical constraint，加 flag 是 over-engineering
- **不**為 resolver 加 cache — 單次 CLI 呼叫生命週期短，AppleScript window enum 本來就便宜，YAGNI
- **不**改變 default targeting 行為 — 沒給 flag 時仍 target front window / document 1，維持 #23 backward compat requirement
- **不**處理 plaud-transcriber skill v1.9.0 的實際 rewrite — 屬於 che-local-plugins downstream consumer 的 follow-up，本 change 只驗證 skill 可以再度使用 `--url plaud` 即可

## Decisions

### Decision: Unify window-scoped commands under `TargetOptions`，delete `WindowOnlyTargetOptions`

**What**: 廢除 `WindowOnlyTargetOptions` struct，所有 window-only commands 改為 `@OptionGroup var target: TargetOptions`。

**Why**: 
- **單一 source of truth**：使用者只需要學一次 targeting syntax
- **CLI surface 完全對稱**：#23 之後「--js / --native 差異」只剩 execution path，不再有 targeting flag 差異
- **type 成本低**：`WindowOnlyTargetOptions` 只存在了一個 release cycle（#23 加入），沒有外部依賴
- **刪除優於擴展**：若擴展 `WindowOnlyTargetOptions` 接受 `--url`，名字 "WindowOnly" 就過時了；重新命名成 `NativeTargetOptions` 又不對（`close` / `screenshot` / `pdf` 和 `--native` flag 無關，它們是「本質上 window-scoped」）。最乾淨的解法是讓 window-only commands 直接用 `TargetOptions` + 新的 resolver method

**Alternatives considered**:

1. **Extend `WindowOnlyTargetOptions` 接受 `--url` / `--document`，不 rename**  
   Rejected：型別名稱與語義分歧，未來讀者要反覆解釋「雖然叫 WindowOnly 但其實接受 --url」。命名債會滾雪球。

2. **Rename `WindowOnlyTargetOptions` → `NativeTargetOptions`**  
   Rejected：`close` 和 `screenshot` AX path 不是「native」的（不走 keystroke），這個名字誤導。

3. **Create a brand new `WindowScopedTargetOptions` type alongside `TargetOptions`**  
   Rejected：兩個幾乎一樣的 type 只為了在 type system 區分「可以 resolve 成 window」vs「可以 resolve 成 document」。區別可以由 `SafariBridge.resolveWindowIndex` 的 caller 保證，不需要 type wall。

### Decision: `SafariBridge.resolveWindowIndex(from: TargetDocument) -> Int` 作為統一 resolver

**What**: 新 async function，接受 `TargetDocument` enum，回傳 physical window index（1-indexed，對應 Safari 的 `window N` AppleScript reference）。

```swift
static func resolveWindowIndex(from target: TargetDocument) async throws -> Int {
    switch target {
    case .frontWindow:
        return 1
    case .windowIndex(let n):
        return n
    case .documentIndex(let n):
        // map document N → window index
    case .urlContains(let pattern):
        // match URL → window index, error on 0 or N>1 matches
    }
}
```

**Why**: 
- **同一 session 內 atomic**：resolver 和後續的 raise / keystroke 在同一個 AppleScript run，消除「documents 跑完到 upload 執行之間視窗重排」的 race condition
- **和既有 `resolveDocumentReference` 家族一致**：`resolveDocumentReference` 回傳 AppleScript reference string，`resolveWindowIndex` 回傳 index int，兩者互補
- **fail-closed error path**：0 match → `documentNotFound`（復用 #23 error），多 match → 新增的 `ambiguousWindowMatch`

**Alternatives considered**:

1. **Putting the logic in `TargetOptions.resolveAsWindowIndex()` directly**  
   Rejected：`TargetOptions` 是 pure ArgumentParser struct，不該有 async I/O。Bridge layer 是 AppleScript 邊界的正確位置。

2. **Making `resolveDocumentReference` overload 回傳 Int 或 String**  
   Rejected：overload 同一個 function name 會讓 call site 模糊。分兩個 function 讀性更好。

### Decision: Multi-match fail-closed with `ambiguousWindowMatch` error

**What**: 當 `--url pattern` 比對到多個 window 時，throw 新 error case：

```swift
case ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, url: String)])
```

Error description 列出所有 matching window index 和 URL，要求使用者更具體。

**Why**:
- **Deterministic** > first-match：AI agent 最怕 silent wrong target。first-match 會因為 Safari window 開啟順序變動而切換目標
- **Automation-friendly** > interactive prompt：CLI 呼叫者無法回應 prompt
- **Discoverable**：error 本身告訴使用者怎麼解決（加長 substring 到 `plaud.ai/file/abc`）
- **和 #23 `documentNotFound` 家族一致**：同樣是 targeting 相關錯誤，應有同樣的「列出可選項」pattern

**Alternatives considered**:

1. **First-match（回傳第一個比對成功的 window）**  
   Rejected：non-deterministic，silent failure mode 對 automation 是 nightmare。

2. **Longest / most-specific match priority**  
   Rejected：引入複雜的 ranking 規則，但對「2 個都是 plaud.ai/file/xxx」這種 case 仍無解。複雜度換來的只是少數 cases 不用加長 substring。

3. **Interactive prompt asking user to pick**  
   Rejected：CLI 被 script 呼叫時沒有 stdin interactive session。

### Decision: Tab auto-switch before keystroke for native path

**What**: 當 resolver 判定 target URL 位於 window N 的 non-current tab T 時，native execution 先執行 AppleScript:

```applescript
tell application "Safari"
    set current tab of window N to tab T
end tell
```

然後 raise window N，再送 keystroke。

**Why**:
- **keystroke 物理 constraint**：System Events keystroke 只能打 front window 的 current tab — 如果目標在 background tab，keystroke 打錯地方
- **briefly switch tab 是 keystroke path 的必要副作用**，與 briefly raise window 同性質，都已由 `--native` / `--allow-hid` flag transitively 授權
- **user intent 清楚**：使用者明確說「upload to plaud」就是想打到 plaud tab，switching 到 plaud tab 完全符合意圖

**Alternatives considered**:

1. **Reject `--tab T` / 多 tab URL 時 fail**  
   Rejected：對稱性差。使用者只要加 `--window N --tab T`（既有 flag 組合）就會期待 targeting 成功。

2. **Require user to pre-switch tab manually**  
   Rejected：等於把 `documents | grep | cut` workaround 改成「你自己切 tab」workaround，沒解決問題。

### Decision: Screenshot AX path does NOT raise target window

**What**: `screenshot --url plaud` 在 `AXIsProcessTrusted()` 為 true 時走 AX bounds path（`_AXUIElementGetWindow` 讀 hidden window bounds → `screencapture -R`），**不** raise window。其他 keystroke-based native primitives（`upload --native`, `pdf`, `close`）照常 raise。

**Why**:
- **Screenshot AX path 物理上不需要 front window** — #23 R6/R7 已經驗證 AX bounds read 對 hidden / background window 有效
- **Non-interference first**：能不 raise 就不 raise。Screenshot 最常見的 use case 是「背景觀察多個視窗」，raise 會破壞這個 workflow
- **Keystroke path 必須 raise**：`upload --native` 的 file dialog 要求 keystroke，keystroke 打 front window，所以必須 raise — 這是 physical constraint 不是 design choice

**Alternatives considered**:

1. **統一所有 native primitives 都 raise**  
   Rejected：對 screenshot 是 regression — #23 R7 已經讓 screenshot AX path 可以讀 hidden window，統一 raise 會讓這個 capability 失效。

2. **加 `--no-raise` opt-out flag**  
   Rejected：over-engineering。Screenshot AX path 天生不需要 raise，keystroke path 天生需要 raise。這是 physical constraint，不是使用者偏好。

### Decision: Stateless resolver — no cache

**What**: Every `resolveWindowIndex` call 都重新呼叫 AppleScript enumerate windows。不做 short-lived cache，不做 process-local memoization。

**Why**:
- **Single CLI invocation ≈ 1 resolve**：大部分 command 只 resolve 一次，cache 沒實益
- **AppleScript window enum 便宜**：Safari 通常 < 10 個 window，enum + URL match < 50 ms
- **YAGNI**：cache 增加的 complexity 大於 perf benefit
- **Correctness**：stateless 保證每次 resolve 都反映當前 state，不會因為 cache staleness 出錯

### Decision: Modify existing `document-targeting` spec, not a new spec file

**What**: 把新 requirement 寫成 `document-targeting` spec 的 MODIFIED / ADDED delta，不另開 `window-resolution/spec.md`。

**Why**:
- **同一個 capability**：window-scoped commands 的 URL resolution 是 document-targeting 的一部分，不是正交能力
- **Delta 延續性**：#23 的 delta spec archive 在 `2026-04-13-multi-document-targeting/`，本 change 的 delta 對應同一個 main spec，archive 時線性延伸
- **避免 spec fragmentation**：把「URL targeting」分散到 2 個 spec 會讓讀者找不到完整定義

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **Race：resolve 完 window 到 raise 之間視窗重排** | Resolve + tab switch + raise + keystroke 在同一個 AppleScript session 內。AppleScript 內部是 single-threaded，window state 在 session 內部不會被外部修改。|
| **`WindowOnlyTargetOptions` 刪除 = BREAKING Swift API** | 這是 Swift internal type（不是 public API），沒有 `@_spi` / `@objc` export。任何 Swift 層呼叫者（目前只有本 repo 的 commands）改成 `TargetOptions`。Plugin / skill 走 CLI 不受影響。|
| **多 Safari instance（STP）** | Out of scope — 本 change 只處理 `Safari.app` bundle。未來要 cover STP 要另開 issue。|
| **Hidden window 截圖 vs visibility gotcha** | #23 R7 spec 已聲明 AX bounds 對 minimized / off-screen window 的行為（throw `accessibilityNotGranted` 或回傳 bounds），本 change 延用不新增。|
| **`ambiguousWindowMatch` error 對現有 `--url` consumer 是 new error case** | 既有 `--url` 在 read-only path 也會遇到多 match（#23 current behavior：first match wins）。為了一致性，考慮是否要 #23 既有 document-scoped path 也升級到 fail-closed。→ **本 change 不動**，只有 window-only path 走新錯誤。`document-targeting` spec 保留既有 "URL substring targeting" scenario 的 "first document whose URL contains" 語義。需要的話另開 follow-up issue 討論是否全面升級。|
| **Tab switch 的視覺副作用** | 使用者透過 `--native` / `--allow-hid` flag 已授權 keystroke interference，tab switch 是同性質副作用。CHANGELOG 需要明確告知。non-interference spec 新增 scenario 聲明這點。|
| **Resolver 和 documents 子命令的語義分歧** | `documents` subcommand 目前列出 `document 1 .. document N`（document collection order），但 resolver 需要 `window 1 .. window N`（physical window order）。兩者在單 tab / 單 window 場景等價，但多 tab 場景不同。文件（CLAUDE.md 更新）需明確兩者差異。|

## Migration Plan

1. 實作 resolver + error case + tab switch（無 CLI 變動，純 Bridge layer）
2. 更新 one command（建議 `upload --native`，因為最痛）讓它走 `TargetOptions` + resolver；舊 `--window N` 直接值繼續運作
3. 測試：確認 `--url plaud` 和 `--window N` 都能打到 Plaud
4. 依序更新 `close`, `screenshot`, `pdf`
5. **最後一步** 刪除 `WindowOnlyTargetOptions.swift`（delete-after-migration，不是 delete-first）
6. 更新 CLAUDE.md / CHANGELOG / spec
7. 發佈 binary → 觸發 plaud-transcriber v1.9.0 驗證

**Rollback**：如果發現 resolver 有問題，可以單獨 revert 最後幾個 commit 把 command 改回 `WindowOnlyTargetOptions`。但建議避免 partial rollback — 因為 mixed state 會讓使用者困惑「為什麼 `upload --native --url` 可以，但 `screenshot --url` 不行」。

## Open Questions

本 change 在 diagnose 階段（#26 comment）列出 6 個 open questions，全部在 discuss 階段收斂並反映在上述 Decisions 中。無新 open question。若 implementation 中發現新議題，回到 idd-ingest 調整。
