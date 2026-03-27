## Why

safari-browser 目前缺少 screenshot、upload、find、storage 等 agent-browser 有的進階功能。本次將所有 Safari + AppleScript 技術上可行的 agent-browser 功能全部補齊，讓 safari-browser 成為 agent-browser 的完整替代方案（macOS 上）。

## What Changes

### 截圖與檔案

- **`screenshot [path]`** — 截取 Safari 視窗截圖，支援 `--full` 全頁截圖。使用 `screencapture -l <windowID>`
- **`upload <selector> <file_path>`** — 透過 System Events 操作檔案對話框上傳檔案

### 元素操作擴充

- **`scrollintoview <selector>`** — 將元素捲動到可見範圍（JS `scrollIntoView()`）
- **`find <locator> <value> [action]`** — 按 text/role/label/placeholder 尋找元素並執行動作（click/fill 等）
- **`highlight <selector>`** — 高亮顯示元素（加紅色 outline），方便 debug

### 狀態查詢擴充

- **`is enabled <selector>`** — 檢查元素是否 enabled
- **`is checked <selector>`** — 檢查 checkbox 是否已勾選
- **`get box <selector>`** — 取得元素的 bounding box（x, y, width, height）

### Storage 管理

- **`cookies get [name]`** — 取得 cookies（全部或指定名稱）
- **`cookies set <name> <value>`** — 設定 cookie
- **`cookies clear`** — 清除所有 cookies
- **`storage local get <key>`** — 取得 localStorage 值
- **`storage local set <key> <value>`** — 設定 localStorage 值
- **`storage local remove <key>`** — 移除 localStorage 項目
- **`storage local clear`** — 清除所有 localStorage
- **`storage session get/set/remove/clear`** — 同上但對 sessionStorage

### Debug 輔助

- **`console`** — 顯示攔截到的 console.log 訊息（透過 JS override `console.log`）
- **`errors`** — 顯示攔截到的 JS 錯誤（透過 `window.onerror`）
- **`mouse move <x> <y>`** — 移動滑鼠到指定座標並觸發 mousemove 事件
- **`mouse down`** / **`mouse up`** — 觸發 mousedown/mouseup 事件
- **`mouse wheel <dy>`** — 觸發 wheel 事件

## Non-Goals

- **snapshot / accessibility tree** — Safari 無 programmatic accessibility API
- **pdf export** — Safari 無 programmatic PDF export
- **network interception**（route/unroute/requests）— Safari 無此 API
- **browser settings**（viewport/device/geo/offline/headers/credentials/media）— Safari 無控制 API
- **trace recording** — Safari 無 trace API
- **session isolation** — Safari 天生共用 session（這是核心優勢）
- **drag and drop** — JS 模擬不可靠

## Capabilities

### New Capabilities

- `screenshot`: Safari 視窗截圖與全頁截圖
- `file-upload`: System Events 檔案對話框上傳
- `find-elements`: 按 text/role/label/placeholder 尋找元素
- `storage-management`: cookies、localStorage、sessionStorage 讀寫
- `debug-tools`: console 攔截、error 攔截、highlight、mouse 事件
- `extended-element-ops`: scrollintoview、get box、is enabled、is checked

### Modified Capabilities

（無）

## Impact

- 新增檔案：`ScreenshotCommand.swift`、`UploadCommand.swift`、`FindCommand.swift`、`CookiesCommand.swift`、`StorageCommand.swift`、`ConsoleCommand.swift`、`ErrorsCommand.swift`、`HighlightCommand.swift`、`MouseCommand.swift`、`ScrollIntoViewCommand.swift`
- 修改檔案：`SafariBrowser.swift`（註冊新子指令）、`GetCommand.swift`（加 `get box`）、`IsCommand.swift`（加 `is enabled`、`is checked`）
