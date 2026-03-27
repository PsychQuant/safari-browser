## Why

目前所有元素操作都需要手寫 CSS selector，使用者必須先 `get source` 或 `js` 查看 DOM 才知道 selector。agent-browser 的 `snapshot -i` → `@ref` 系統讓 AI agent 能快速發現頁面上的互動元素並操作，safari-browser 需要對等的能力。

## What Changes

- **`snapshot` 指令** — 用 JS 掃描 DOM 中所有互動元素（input, button, a, select, textarea, `[role=button]`, `[onclick]` 等），分配 `@e1, @e2...` ref ID，存到 `window.__sbRefs` 陣列，輸出可讀的元素清單
- **`-i` / `--interactive` 旗標** — 只顯示互動元素（預設行為，未來可擴充為全部元素）
- **`-s` / `--selector` 選項** — 限定掃描範圍到指定 CSS selector 內的子元素
- **@ref 解析** — 所有接受 selector 參數的指令（click, fill, type, select, hover, focus, check, uncheck, dblclick, scrollintoview, highlight, get text/html/value/attr/box, is visible/enabled/checked）偵測 `@eN` 格式，從 `window.__sbRefs` 查找對應元素

## Non-Goals

- Accessibility tree（Safari 無 API）
- 自動 re-snapshot（頁面變化後需手動重新 `snapshot`）
- 非互動元素的 ref（如 div, span — 可用 CSS selector）

## Capabilities

### New Capabilities

- `snapshot`: 掃描互動元素並分配 @ref ID
- `ref-resolution`: 所有 selector 參數支援 @eN ref 格式

### Modified Capabilities

（無 — ref resolution 是在指令層透過 JS 解析，不改 spec 層級的行為定義）

## Impact

- 新增：`Sources/SafariBrowser/Commands/SnapshotCommand.swift`
- 修改：所有接受 selector 的 Command（透過共用的 ref resolution JS 前綴，不改個別檔案 — 在 SafariBridge 加 helper）
