## Why

#129：使用者選 target 前的 documents/tabs 列表缺少視窗 dialog 狀態。

## What Changes

- 保留分頁資料的 stable window ID。
- 同一個 #128 有界 snapshot 提供每視窗觀測，保留既有 dialog scan 行為。
- 每列 JSON blocking_dialog 與文字標記；unknown 不誤稱 clear。

## Capabilities

### New Capabilities
- `window-dialog-listing`: discovery 列的可見 native dialog 狀態。

## Impact

DialogTreeScanner、GlobalDialogProbe、SafariBridge 的分頁 DTO、DocumentsCommand/TabsCommand 與測試。沒有新作用中分頁切換、dismiss 或 HID。
