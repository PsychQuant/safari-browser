## Why

#23 把 `--url` / `--window` / `--tab` / `--document` targeting 接到了 read-only queries、`upload --js`、storage、wait、snapshot 等 document-scoped path，但 **window-only primitives**（`close`、`screenshot` AX mode、`pdf`、`upload --native`、`upload --allow-hid`）只接受 `--window N`，不接受 `--url pattern`。這是 #23 R5 的刻意取捨：native 用 System Events keystroke，物理上只能打 front window，所以不該假裝能 target 任意 document。

但這個限制把「keystroke 必須打 front」和「URL 不能 resolve 到 window」混為一談。實際上我們可以在 Swift 層把 URL pattern **resolve 成 window index**，然後走既有的 `--native --window N` path（brief raise → keystroke）。這補齊了 #23 未 cover 的 native path，消除 shell workaround `documents | grep -n plaud | cut -d: -f1`，同時維持既有的 physical constraint 不變。

迫切性：#24 把 `upload --js` 硬上限降到 10 MB 之後，所有大檔上傳**強制**走 `--native`；#24 之前還可以用 `--js --url plaud` 規避這個缺口，現在徹底斷路。che-local-plugins plaud-transcriber 因此在 v1.8.2 被手動 rewrite 成「請手動切到 Plaud tab」，把 #23 原本解決的 non-interference / AI-agent autonomy 又吐了回去。

## What Changes

- **window-only primitives 接受完整 `TargetOptions`**：`close`、`screenshot`、`pdf`、`upload --native`、`upload --allow-hid` 從只接受 `--window` 擴展成接受 `--url` / `--window` / `--tab` / `--document`，與 #23 的 document-scoped path 語義對稱
- **新增 `SafariBridge.resolveWindowIndex(from: TargetDocument) -> Int`**：把 `TargetDocument` case 統一 resolve 成 window index（physical window 編號，不是 document order）— `urlContains` match URL 找所在 window；`documentIndex` / `tab` 從 document collection 反推 window；`windowIndex` 直接 pass-through；`frontWindow` 回傳 1
- **多 match 錯誤路徑**：新增 `SafariBrowserError.ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, url: String)])`，當 URL substring 比對到多個 window 時 fail-closed 並列出所有 matches + window index
- **Tab auto-switch for native path**：當 resolver 判定 target document 位於 window N 的 non-current tab 時，native 執行流程先 `set current tab of window N to tab T` 再 keystroke — briefly switch tab 是 keystroke path 的必要副作用，與 briefly raise window 同性質
- **統一 targeting type**：廢除 `WindowOnlyTargetOptions`，window-only commands 改為 `@OptionGroup var target: TargetOptions` + `resolveWindowIndex`；單一 source of truth，CLI 語義完全對稱
- **Screenshot AX path 不 raise**：`screenshot --url plaud` 在有 Accessibility 權限時走 AX bounds path（`_AXUIElementGetWindow`）讀 hidden window 截圖，**不** raise 該 window — 這是最 non-interfering 的結果，與其他 keystroke-based primitives 不同
- **`--tab` 語義**：對 window-only commands，`--tab N` 等同 `--document N`（#23 既有 alias），但 resolver 會把它 map 成 (window, tab-in-window) pair 供 native path tab-switch 使用
- **CLI error message 更新**：#23 R5 的 `--native / --allow-hid only supports --window` 錯誤訊息刪除 — 不再是有效的 invariant
- **BREAKING: `WindowOnlyTargetOptions` struct 移除**：Swift internal type，沒有 public API 契約，但任何直接 import 這個 type 的 downstream code 需要改用 `TargetOptions`。Marketplace plugin、skills 不受影響（走 CLI layer）
- **plaud-transcriber skill v1.9.0**：移除手動切 tab 提醒，恢復 `--url plaud` 寫法（屬於 che-local-plugins 的 downstream consumer update，不在本 spec 實作範圍內，但會在 apply 階段驗證）

## Capabilities

### New Capabilities

(none — 本 change 擴展既有 capabilities，不新增)

### Modified Capabilities

- `document-targeting`: 新增 "Native path URL resolution" requirement，允許 `--url` / `--document` / `--tab` 在 native/window-only primitives 上透過 Swift 層 resolver 運作；更新既有 "Backward compatibility" requirement 的 keystroke scenario 以反映 new opt-in behavior（沒 flag 時仍 front window，有 flag 時走 resolver）
- `file-upload`: 更新 `upload --native` 的 targeting 契約，從「只接受 `--window`」改為「接受完整 `TargetOptions`」；明確 tab auto-switch 行為
- `pdf-export`: 同 file-upload，`pdf` 接受完整 `TargetOptions`
- `screenshot`: 同 file-upload，`screenshot` 接受完整 `TargetOptions`；AX path 不 raise hidden window
- `non-interference`: 新增 scenario 聲明 native path 的 brief tab switch 屬於「passively interfering」副作用，已獲使用者授權（transitively 透過 `--native` / `--allow-hid` flag）

## Impact

**Affected specs**:
- `openspec/specs/document-targeting/spec.md`（主要 delta）
- `openspec/specs/file-upload/spec.md`
- `openspec/specs/pdf-export/spec.md`
- `openspec/specs/screenshot/spec.md`
- `openspec/specs/non-interference/spec.md`

**Affected code**:
- `Sources/SafariBrowser/SafariBridge.swift` — 新 `resolveWindowIndex(from:)`, AppleScript tab-switch helper
- `Sources/SafariBrowser/Commands/TargetOptions.swift` — 可能新增 `resolveAsWindowIndex()` convenience method（呼叫 Bridge）
- `Sources/SafariBrowser/Commands/WindowOnlyTargetOptions.swift` — **刪除**
- `Sources/SafariBrowser/Commands/UploadCommand.swift` — `validate()` 移除 #23 R5 reject，`run()` 改呼叫 resolver
- `Sources/SafariBrowser/Commands/CloseCommand.swift` — 改用 `TargetOptions`
- `Sources/SafariBrowser/Commands/ScreenshotCommand.swift` — 改用 `TargetOptions`，AX path 加 no-raise 邏輯
- `Sources/SafariBrowser/Commands/PdfCommand.swift` — 改用 `TargetOptions`
- `Sources/SafariBrowser/Utilities/Errors.swift` — 新增 `ambiguousWindowMatch` case
- `Tests/SafariBrowserTests/CommandParsingTests.swift` — 每個 primitive × 3 scenarios（0 match / 1 match / N match）+ tab-switch test
- `CLAUDE.md` — multi-window section 更新（移除「native 只接受 `--window`」註解）
- `CHANGELOG.md` — enhancement entry
- Downstream: `che-local-plugins/plugins/plaud-transcriber/skills/plaud-upload/SKILL.md` — apply 階段驗證，不在本 repo 內
