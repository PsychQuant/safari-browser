## Why

safari-browser 目前有 33 個指令，已涵蓋大部分 agent-browser 功能。但要成為 macOS 上的完整替代方案（排除 headless 和 Safari 技術上不可能的功能），還有 7 項差距需要補齊：PDF export、`--json` 結構化輸出、snapshot 改善（compact + depth）、drag and drop、console 多層級攔截、dark/light mode 切換。

## What Changes

### PDF Export
- **`pdf <path>`** — 透過 System Events 觸發 Safari 的 File > Export as PDF，儲存到指定路徑

### JSON 結構化輸出
- **`--json` 全域 flag** — `snapshot`、`tabs`、`get box`、`cookies get` 等指令加入 `--json` 選項，輸出 JSON 格式供 AI agent 解析

### Snapshot 改善
- **`snapshot -c`** (compact) — 移除隱藏和不可見的元素
- **`snapshot -d <n>`** (depth) — 限制掃描的 DOM 深度
- 改善元素描述：顯示 id、class（前 3 個）、disabled 狀態

### Drag and Drop
- **`drag <srcSelector> <dstSelector>`** — 透過 JS 模擬 dragstart → dragover → drop → dragend 事件序列

### Console 分級攔截
- 擴充 `console --start` 攔截所有層級：log、warn、error、info、debug，輸出時標記層級

### Media 設定
- **`set media dark`** / **`set media light`** — 透過 JS override CSS media query `prefers-color-scheme`

## Non-Goals

- Network interception（route/unroute/requests）— Safari 無 API
- Viewport/device/geo/offline emulation — Safari 無 API
- Custom headers/credentials injection — Safari 無 API
- Trace recording — Safari 無 API
- Session isolation — Safari 天生共用（核心優勢）
- Headless — 不需要

## Capabilities

### New Capabilities

- `pdf-export`: Safari Export as PDF 功能
- `json-output`: 結構化 JSON 輸出支援
- `drag-and-drop`: JS 模擬拖放事件
- `media-settings`: dark/light mode 切換

### Modified Capabilities

- `snapshot`: 新增 compact、depth、改善元素描述
- `debug-tools`: console 分級攔截（log/warn/error/info/debug）

## Impact

- 新增：`PdfCommand.swift`、`DragCommand.swift`、`SetCommand.swift`
- 修改：`SnapshotCommand.swift`（compact + depth + 改善描述）、`ConsoleCommand.swift`（分級）、`TabsCommand.swift`（--json）、`GetCommand.swift`（box --json）、`CookiesCommand.swift`（--json）、`SafariBrowser.swift`（註冊新指令）
