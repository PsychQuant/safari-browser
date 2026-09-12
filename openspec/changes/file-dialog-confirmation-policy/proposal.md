## Problem

#107 的確認公告在成功的子程序路徑被丟棄；catch 同時涵蓋查找與 click，可能重播 Return。PDF 覆寫缺少獨立授權。

## Root Cause

程序 runner 只在錯誤使用 stderr；單一 try 混合查找與副作用；--allow-hid 沒有區分路徑選擇與覆寫。

## Proposed Solution

檔案對話框入口安全傳遞 trace，兩個 pipe 同時排空。Initial confirmation 僅在 dispatch 前查找失敗保留 Return fallback，dispatch 後失敗不重播。PDF 以 --overwrite 控制既有目的檔案及 replacement sheet，僅具名 Replace/取代可確認。文件明列初始確認例外與待實測的 AX 等價性。

## Success Criteria

非 GUI 程序／建構測試證明紀錄、原錯誤、timeout 與不重播；自有 file panel 實機驗收後才宣告 verified。不使用 Print route 產生列印工作。

## Impact

- SafariBridge subprocess runner／fileDialogNavigationScript、PdfCommand、UploadCommand。
- FileDialogDiagnostics helper 與測試、operation-paths、non-interference／pdf-export 規格。

## Capabilities

### New Capabilities
- file-dialog-confirmations: 可追蹤的確認、不重播與覆寫授權。

### Modified Capabilities
- pdf-export: initial confirmation 與獨立覆寫授權。
- non-interference: 具名檔案確認例外。
