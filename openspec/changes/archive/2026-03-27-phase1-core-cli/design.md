## Context

macOS 原生瀏覽器自動化工具。2026-03-21 在 Plaud 網站的實戰中發現 agent-browser (Playwright/Chromium) 有根本性問題：

1. 每次啟動是全新 Chromium，cookies/localStorage 不保留
2. `state save/load` 不穩定（headed/headless 不互通）
3. `fill` 在 Vue 網站常失敗（reactivity 不觸發）
4. 90% 的操作最終都用 `eval` 跑 JS，snapshot/ref 系統用不上

Safari 的 AppleScript 介面直接操作使用者現有的瀏覽器 session，localStorage 跨 session 永久保留。

## Goals / Non-Goals

**Goals:**

- 建立 Swift CLI，透過 AppleScript 控制 Safari
- Phase 1 涵蓋：導航、JS 執行、頁面資訊、Tab 管理、等待機制
- CLI 介面風格與 agent-browser 對齊，降低學習成本

**Non-Goals:**

- 檔案上傳（System Events）— Phase 2
- 截圖（screencapture）— Phase 2
- 非同步 JS（`--async`、`--wait N`）— Phase 2
- Claude Code Plugin 包裝 — Phase 3
- 跨平台、Headless — 永遠不做

## Decisions

### Swift CLI + osascript 橋接

選擇 Swift CLI 而非 shell 腳本或純 skill：

| 選項 | 優點 | 缺點 |
|------|------|------|
| A. Shell 腳本包裝 osascript | 零依賴、立即可用 | 不好維護、效能差 |
| B. Swift CLI | 原生 API、效能好、跟其他 che MCP 一致 | 需要編譯 |
| C. 純 Claude Code skill | 最簡單 | 無法重用、其他專案不能用 |

**決定：選項 B。** 跟 che-ical-mcp、che-svg-mcp 等既有工具一致的開發模式。使用 `swift-argument-parser` 處理子指令路由。

### AppleScript 執行方式：Process.osascript 而非 ScriptingBridge

雖然 Swift 有 ScriptingBridge 可直接呼叫 Safari API，但 Safari 的 ScriptingBridge 支援不完整（`do JavaScript` 無法透過 ScriptingBridge 呼叫）。因此統一使用 `Process` 執行 `osascript -e` 指令。

優點：所有 AppleScript 功能都可用，實作簡單。
缺點：每次呼叫有 process spawn 開銷（約 50-100ms），可接受。

### Safari AppleScript 能力對照

| 功能 | AppleScript 指令 | 備註 |
|------|-----------------|------|
| 開 URL | `open location` 或 `set URL of tab` | |
| 執行 JS | `do JavaScript` | 回傳值為字串 |
| 取 URL | `get URL of current tab` | 原生屬性 |
| 取標題 | `get name of current tab` | 原生屬性 |
| 取純文字 | `get text of current tab` | 原生屬性 |
| 取 HTML | `get source of current tab` | 原生屬性 |
| 列出 tab | `get name of every tab` | |
| 切換 tab | `set current tab to tab N` | |
| 新 tab | `make new tab with properties {URL:...}` | |
| 關 tab | `close current tab` | |
| 前進/後退 | `do JavaScript "history.back()"` | 無原生指令 |

### 專案結構

```
safari-browser/
├── Package.swift
├── Sources/
│   └── SafariBrowser/
│       ├── SafariBrowser.swift       # @main 進入點 + 子指令路由
│       ├── SafariBridge.swift         # AppleScript 橋接層
│       ├── Commands/
│       │   ├── OpenCommand.swift      # open
│       │   ├── JSCommand.swift        # js
│       │   ├── GetCommand.swift       # get (url/title/text/source)
│       │   ├── TabsCommand.swift      # tabs
│       │   ├── TabCommand.swift       # tab <n> / tab new
│       │   ├── WaitCommand.swift      # wait
│       │   ├── BackCommand.swift      # back
│       │   ├── ForwardCommand.swift   # forward
│       │   ├── ReloadCommand.swift    # reload
│       │   └── CloseCommand.swift     # close
│       └── Utilities/
│           └── Errors.swift           # 錯誤類型定義
└── Tests/
    └── SafariBrowserTests/
```

### 與 agent-browser 的 CLI 介面對照

| 功能 | agent-browser | safari-browser |
|------|--------------|----------------|
| 登入 | 每次重新登入 | 永遠登入 |
| JS 執行 | `eval` | `js` |
| 元素發現 | `snapshot -i` → `@ref` | 直接寫 JS selector |
| 等待 | `wait` | `wait` |
| 並行 | 多 session | 多 tab/window |

## Risks / Trade-offs

- **[do JavaScript 回傳值限制]** → 回傳值必須是字串，約 1MB 上限。超過需使用者自行 `JSON.stringify()` 並分段取。無需特殊處理，文件說明即可。
- **[Async JS 不支援 Promise]** → `do JavaScript "fetch(...).then(...)"` 立即回傳 Promise 字串表示，不會等結果。Phase 1 不處理，Phase 2 的 `--async` / `--wait` 會解決。
- **[Safari 未啟動]** → `open location` 會自動啟動 Safari，但首次需使用者授予 AppleScript 權限。CLI 偵測到權限錯誤時輸出明確提示。
- **[Accessibility 權限]** → Phase 1 不需要（System Events 是 Phase 2 upload 才用）。
