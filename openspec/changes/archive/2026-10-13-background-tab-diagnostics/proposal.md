## Why

#131：背景分頁上的 pending dialog 尚未呈現於 AX 樹，JS timeout 或 get text 空字串因此缺乏有用提示。

## What Changes

- 保留穩定的 window ID／tab index 供失敗後診斷。
- 以新鮮、有界、唯讀的活動分頁查詢，僅對已確認背景狀態發出 stderr 提示。
- 保留原錯誤、空文字語意及可見 dialog 的優先處理；不自動操作分頁。
- 補純／整合測試、隔離 GUI 驗收腳本與 README 邊界說明。

## Capabilities

### New Capabilities
- `background-tab-diagnostics`: 背景 target 的 pending dialog 診斷提示。

## Impact

SafariBridge 的 target DTO、JS timeout 與 getText 空結果路徑。正常結果不增加診斷查詢。實機驗收待解除 Mac 鎖定。
