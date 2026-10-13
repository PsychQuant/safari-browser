## Why

#167：目前只能觀察整體耗時，無法分辨 CLI 啟動、目標解析、AppleScript／daemon 傳輸、編譯與 AX 讀取成本。後續 #168–#172 需要相同且可重跑的基準。

## What Changes

- 加入預設關閉的 `SAFARI_BROWSER_TRACE_TIMING=1` 計時摘要；固定 schema，只含階段、父子關係、耗時與狀態，不含操作內容。
- 將計時接到 CLI、target resolver、router／程序與 AX worker；明確 opt-in 的 daemon 請求可附回有界服務端計時。
- 加入受限情境的 benchmark 工具與 cold／warm 報告，缺少所需環境時明示 SKIP。

## Capabilities

### New Capabilities
- `command-performance-observability`: request-local 分段計時與可重現基準格式。

### Modified Capabilities
無。原有輸出、錯誤、取消、截止與不重播契約保留；計時只在顯式啟用時使用 stderr／可選附加 metadata。

## Impact

`SafariBrowser.main`、共用 bridge／router／AX worker、daemon 編譯快取及 exec envelope；新增 `PerformanceTrace`、benchmark 工具、Swift／Python 回歸與使用說明。不增加公開 CLI leaf／MCP tool，也不修改安裝的 binary。
