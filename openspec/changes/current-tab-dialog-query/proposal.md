## Problem

#108 的 click 在 handler 內開出原生 confirm 後仍等待 JavaScript 返回；入口探測不能預知這個面板，既有 is 子命令也依賴同一條 JavaScript 路徑。

## Root Cause

目前缺少可在 JavaScript 等待期間獨立執行、且能區分未知狀態的目前分頁查詢。

## Proposed Solution

採 issue 原始允許的方案 (b)：新增 is dialog 與 --json，使用有界 AX 身分讀取及既有 strict scanner，只觀察 Safari 主視窗；present/clear/unknown 各有明確輸出。查詢不執行 JavaScript 或 Apple Event、不 activate 或按按鈕。

## Success Criteria

click 子程序因自有 confirm 保持等待期間，獨立 is dialog 能在 30 秒 timeout 前回報 true；unknown 不得轉成 false。單一 AX worker、800 ms 預算、完整性與身分重新確認皆有測試，GUI 驗收保留自有面板完整清理。

## Capabilities

### New Capabilities
- current-tab-dialog-query: 主視窗所選分頁的原生 dialog 三態查詢。

### Modified Capabilities
無。

## Impact

- 新 CurrentWindowDialogProbe、IsDialog 命令及 IsCommand 註冊。
- AXDialogProbeProvider 的有界主視窗讀取、DialogTreeScanner 的指定根視窗入口。
- provider／command／MCP metadata 測試、自有 live fixture、README。
