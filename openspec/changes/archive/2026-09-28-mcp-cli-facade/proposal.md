## Why

#110要求保留CLI並新增由ArgumentParser metadata產生schema的MCP stdio介面。實測目前有78個葉節點、76個公開葉節點；OptionGroup已展開，但metadata不提供Swift scalar型別或runtime互斥條件。

## What Changes

- 新增 `safari-browser mcp`，runtime讀同一build的 `_dumpHelp()` serializationVersion 0，產生全部既有公開tool；排除隱藏指令與MCP本身。
- 參數以positionals/options/stdin物件傳入，形狀驗證由產生的schema與mapper處理，真正值域與互斥驗證仍由既有command struct處理。
- 隔離worker直接重用CLI parser/command，保留stdin/stdout/stderr/exit與不確定結果，並避免隱含daemon轉派、重建後混用不同engine。
- stdio支援2026-07-28 per-request metadata與2025-06-18/2025-11-25 legacy initialize，含取消、錯誤、分頁與輸出隔離測試。

## Capabilities

### New Capabilities
- `mcp-cli-facade`: metadata目錄、CLI worker及MCP stdio。

### Modified Capabilities
無。既有公開CLI指令與daemon保留；新增模式以外不改行為。

## Impact

SafariBrowser註冊與internal worker guard、DaemonRouter內部MCP直送標記、新增MCP目錄/runner/protocol/transport模組、測試與README。不新增第三方套件，不發行mcpb，不變更TCC或安裝binary。
