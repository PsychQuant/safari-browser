## Why

agent-browser (Playwright/Chromium) 在需要登入的網站自動化場景中表現不佳 — 每次啟動是全新瀏覽器、session 不保留、`state save/load` 不穩定。2026-03-21 的 Plaud 實戰證實：90% 的操作最終都用 `eval` 跑 JS，snapshot/ref 系統用不上。Safari 的 AppleScript 介面直接使用使用者現有的 session（localStorage、cookies 永久保留），能一勞永逸解決登入問題。

## What Changes

建立 `safari-browser` Swift CLI，提供以下核心功能：

- **URL 導航**：開啟 URL（現有 tab / 新 tab / 新視窗）、上一頁、下一頁、重新載入
- **JavaScript 執行**：在當前 tab 執行 JS 並回傳結果，支援從檔案執行
- **頁面資訊取得**：取得當前 URL、標題、純文字、HTML 原始碼
- **Tab 管理**：列出所有 tab、切換 tab、開新 tab、關閉 tab
- **等待機制**：等待指定毫秒、等待 URL 匹配 pattern、等待 JS 表達式為 truthy

## Non-Goals

- **檔案上傳**（System Events）— Phase 2
- **截圖**（screencapture）— Phase 2
- **非同步 JS 執行**（`--async`、`--wait`）— Phase 2
- **Claude Code Plugin 包裝** — Phase 3
- **跨平台支援** — 永遠不做，這是 macOS-only 工具
- **Headless 模式** — Safari 不支援，不做

## Capabilities

### New Capabilities

- `navigation`: URL 導航（open、back、forward、reload、close）
- `js-execution`: JavaScript 執行與結果回傳
- `page-info`: 頁面資訊取得（url、title、text、source）
- `tab-management`: Tab 列表、切換、新增、關閉
- `wait`: 時間等待、URL pattern 等待、JS 條件等待

### Modified Capabilities

（無）

## Impact

- 新增程式碼：Swift Package（`Package.swift`、`Sources/`、`Tests/`）
- 依賴：Swift 6.0+、macOS Sequoia 15+、`swift-argument-parser`
- 系統權限：Safari 的 AppleScript 存取權限（首次執行時系統會詢問）
- 安裝位置：編譯後的 binary 放到 `/Users/che/bin/safari-browser`
