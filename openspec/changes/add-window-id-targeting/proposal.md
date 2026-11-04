## Why

`--window N` 以視窗的前後順序指定視窗。任何視窗被拉到前面（包括 safari-browser 自己的 `activate`），這個編號就指到別的視窗。好幾條路徑先把視窗解析成編號、再在另一個 Apple event 裡對 `window N` 動作，兩者之間順序一變就打到別的視窗，可能是別人的 profile。2026-11-04 實測：多個視窗、Safari 不在前景時，`open --new-tab`（`--profile` 與 `--window 1`）三次都開到別的視窗（#351）。下游的 Akashic `fulltext fetch` 因此在有別的 profile 視窗開著時只能整個停下（PsychQuant/Akashic-Library#768）。

視窗 id（`id of window`）在視窗存活期間不變，`documents --json` 已以 `blocking_dialog.window_id` 回報它，#79／#180 也已在內部用它錨定 `js` 的目標。缺的是使用者能直接指定它的方式。

## What Changes

- `TargetOptions` 新增 `--window-id <W>`：所有組合 `TargetOptions` 的指令都能用。
  - 單獨使用：目標是 `window id W` 的目前分頁（新的 `TargetDocument.windowID`，參照 `document of window id W`）；`js`、`wait` 的非同步錨定再以既有的 `SafariBridge.readWindowAnchor(windowID:)` 轉成 `.anchoredCurrentTab`。
  - 配 `--tab-in-window T`：目標是 `tab T of window id W`（`.resolvedTab`）。
  - 與 `--window`、`--url`／`--url-exact`／`--url-endswith`／`--url-regex`、`--tab`、`--document` 互斥。
  - 配 `--profile P`：視窗 W 必須屬於 P，否則失敗。
  - 視窗 W 不存在：失敗（`documentNotFound`），**絕不**退回 `front window`。
- `open`：
  - 自己的 `hasExplicitTarget` 計入 `--window-id`（否則重演 safari-browser#233：沒指定目標的 `open` 會在前景視窗開新分頁）。
  - `open --new-tab --window-id W`：在 `window id W` 建分頁，**不** `activate`，新分頁仍設成那個視窗的目前分頁（維護者 2026-11-05）。
  - `open --new-tab --window N`：在 `activate` **之前**讀出 `id of window N`，再在 `window id <那個 id>` 建分頁（#351，取自本機 commit `b5ab06b` 的 `SafariBridge.NewTabWindow`／`openURLInNewTabScript`）。
  - `open --new-tab --profile P [--window k]`：用 profile 篩選的列舉本來就讀到的視窗 id，不再以位置重新查（#351 更正後的病因：`concreteTarget` 對視窗層級的解析丟掉了 id）。
- `exec`：in-process dispatcher 接受 `--window-id`，重組參數時帶上它。
- `documents --json`：每一列在最上層加 `window_id`（與 `blocking_dialog.window_id` 同值；讀不到時為 null，#349）。
- `tab <N>`／`tab new`：與 `open --new-tab` 同樣的視窗處理（`--window-id` 先確認存在再以 id 指定、`tab new` 不 `activate`；`--profile` 用列舉讀到的 id；`tab new --window N` 先讀 id 再 `activate`）。`tab focus` 以解析出的視窗 id 切分頁（verify 第一輪補上：原本漏掉 `tab`）。
- `--window N` 維持位置語意（維護者 2026-11-05）。

## Non-Goals (optional)

- `close`、`screenshot`、`pdf`、`upload --native` 這些視窗層級的原始動作（拆到 #353）。
- 分頁的穩定身分（#188）。
- 開了多個視窗時對 `--window N` 警告或拒絕（#287）。
- `open --new-tab` 不用 `--window-id` 時的 `activate` 行為（#350 其餘部分）；`open --window-id W <url>`（導航）仍會 `activate`。
- 讓**每個**指令都在開頭把 `--window N` 解析成 id 一次。`js`、`wait`、`save-pdf` 已經這樣做（#180）；其他指令維持每次 Apple event 依位置解析（與先前相同）。診斷時記下的「resolved to an id once」只在這些指令成立，其餘由 #354 追蹤。
- `open` 的 focus-existing 在「同 Space 別的視窗」層會先 raise 視窗再以 `window N` 切分頁（issue 第一點涵蓋的視窗層級動作之一），與 `close` 等同屬 #353 的範圍。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `document-targeting`: 新增「以視窗 id 指定視窗」的 requirement（`--window-id`、互斥、profile 檢查、fail closed）。
- `navigation`: 「Open URL in new tab」改為以視窗 id 建分頁，並接受 `--window-id`、`--profile`。
- `document-listing`: JSON 每列加 `window_id`。
- `tab-management`: 「Switch to tab by index」與「Open new empty tab」接受 `--window-id`，`--profile` 以 id 指定。

## Impact

- Affected specs: `document-targeting`, `navigation`, `document-listing`, `tab-management`
- Affected code:
  - `Sources/SafariBrowser/Commands/TargetOptions.swift`
  - `Sources/SafariBrowser/SafariBridge.swift`
  - `Sources/SafariBrowser/Commands/OpenCommand.swift`, `Sources/SafariBrowser/Commands/TabCommand.swift`
  - `Sources/SafariBrowser/Commands/DocumentsCommand.swift`
  - `Sources/SafariBrowser/Exec/CommandDispatch.swift`, `Sources/SafariBrowser/Exec/ScriptInterpreter.swift`
  - Tests: `Tests/SafariBrowserTests/`（新增 `WindowIDTargetingTests.swift`、`OpenNewTabWindowTests.swift`）
- 假設（無人可問，記在這裡供挑戰）：`--window-id` 配 `--first-match` 不影響行為（id 只會對到一個視窗）；`--window-id` 配 `--mark-tab` 照一般目標處理。
