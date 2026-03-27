## Why

填完表單後無法按 Enter 提交、無法 Tab 切換欄位、無法 Escape 關閉 modal，是目前 safari-browser 最大的操作缺口。此外 focus、checkbox 操作、雙擊也是常見的自動化需求。

## What Changes

新增 4 個子指令：

- **`press <key>`** — 模擬鍵盤按鍵（Enter、Tab、Escape、ArrowDown 等），支援修飾鍵組合（如 `Control+a`、`Shift+Tab`）
- **`focus <selector>`** — 聚焦到指定元素
- **`check <selector>`** / **`uncheck <selector>`** — 勾選/取消勾選 checkbox
- **`dblclick <selector>`** — 雙擊元素

## Non-Goals

- 完整的鍵盤 input simulation（逐字觸發 keydown/keypress/keyup）— 用 `fill`/`type` 處理文字輸入
- 組合鍵觸發瀏覽器原生功能（如 Cmd+T 開新 tab）— Safari AppleScript 已有對應指令

## Capabilities

### New Capabilities

- `keyboard`: press 鍵盤按鍵，支援常見按鍵名稱和修飾鍵組合
- `extra-interaction`: focus、check、uncheck、dblclick

### Modified Capabilities

（無）

## Impact

- 新增檔案：`Sources/SafariBrowser/Commands/PressCommand.swift`、`FocusCommand.swift`、`CheckCommand.swift`、`DblclickCommand.swift`
- 修改檔案：`Sources/SafariBrowser/SafariBrowser.swift`（註冊新子指令）
