## Why

目前與網頁元素互動都要手寫完整 JS（如 `safari-browser js "document.querySelector('button').click()"`），冗長且容易出錯。agent-browser 有 `click`、`fill`、`select` 等便利指令，safari-browser 也需要對等的高頻操作指令來提升可讀性和易用性。

## What Changes

新增以下便利子指令，內部均透過 `SafariBridge.doJavaScript` 實作：

- **`click <selector>`** — 點擊符合 CSS selector 的第一個元素
- **`fill <selector> <text>`** — 清空並填入文字到 input/textarea，同時觸發 input 和 change 事件
- **`type <selector> <text>`** — 在現有值後面追加文字，觸發 input 事件
- **`select <selector> <value>`** — 選擇 `<select>` 下拉選單的選項
- **`hover <selector>`** — 對元素觸發 mouseover 事件
- **`scroll <direction> [pixels]`** — 捲動頁面（up/down/left/right）
- **`get text <selector>`** — 取得指定元素的 textContent（擴充現有 `get` 指令）
- **`get html <selector>`** — 取得指定元素的 innerHTML
- **`get value <selector>`** — 取得 input/textarea 的值
- **`get attr <selector> <name>`** — 取得指定元素的屬性值
- **`get count <selector>`** — 計算符合 selector 的元素數量
- **`is visible <selector>`** — 檢查元素是否可見
- **`is exists <selector>`** — 檢查元素是否存在

## Non-Goals

- **snapshot / ref 系統** — agent-browser 的 `@ref` 機制不適用，Safari 無 accessibility tree API，直接用 CSS selector
- **drag and drop** — 純 JS 模擬不可靠，暫不做
- **file upload** — Phase 2（需 System Events）
- **screenshot / pdf** — Phase 2
- **network interception** — Safari AppleScript 不支援
- **cookie / localStorage 管理指令** — `js` 已可完成，不額外包裝

## Capabilities

### New Capabilities

- `element-interaction`: 點擊、填入、選擇、hover、scroll 等元素互動指令
- `element-query`: 取得元素文字/HTML/值/屬性/數量，檢查元素狀態

### Modified Capabilities

- `page-info`: 擴充 `get` 子指令，新增 `text <selector>`、`html <selector>`、`value <selector>`、`attr <selector> <name>`、`count <selector>` 子選項

## Impact

- 新增檔案：`Sources/SafariBrowser/Commands/ClickCommand.swift`、`FillCommand.swift`、`TypeCommand.swift`、`SelectCommand.swift`、`HoverCommand.swift`、`ScrollCommand.swift`、`IsCommand.swift`
- 修改檔案：`Sources/SafariBrowser/Commands/GetCommand.swift`（擴充 selector 查詢）、`Sources/SafariBrowser/SafariBrowser.swift`（註冊新子指令）
