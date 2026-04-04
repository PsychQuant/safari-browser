## 1. Vision Worker：Swift CLI + MLXVLM（Analyze screenshot with FastVLM、Setup and download model、Fast inference）

- [x] 1.1 建立 `safari-vision` Swift Package：Package.swift 加入 `mlx-swift-lm`（MLXVLM）+ `mlx-swift-lm-huggingface`（TokenizersLoader）+ `mlx-swift-lm-tokenizers` 依賴，設定 macOS 15+
- [x] 1.2 實作 `safari-vision setup` 指令：Setup and download model，用 MLXVLM 的 loadModel 預下載 `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` 到 Hugging Face cache
- [x] 1.3 實作 `safari-vision analyze <image> <prompt>` 指令：Analyze screenshot with FastVLM，用 MLXVLM ChatSession.respond(to:image:) 生成文字到 stdout
- [x] 1.4 驗證 Fast inference：在 Apple Silicon 上測試推論速度
- [x] 1.5 `make install` 編譯 safari-vision 到 `~/bin/safari-vision`，含 codesign

## 2. 三層架構：Channel Server + Vision Worker + Monitor Loop — Bun MCP（MCP server with channel capability、Push page change notifications、Channel instructions）

- [x] 2.1 建立 `channel/` 目錄：`package.json`（依賴 `@modelcontextprotocol/sdk`）、`bun install`
- [x] 2.2 實作 `channel/channel.ts`：MCP server with channel capability，宣告 `claude/channel` experimental capability，透過 StdioServerTransport 連接
- [x] 2.3 實作 Channel instructions：撰寫 instructions 字串說明 `<channel source="safari-vision">` 事件格式

## 3. Monitor Loop：智慧 diff — 截圖 + VLM（Periodic screenshot and analysis、Change detection、Temporary file cleanup）

- [x] 3.1 實作 Periodic screenshot and analysis：setInterval 呼叫 `safari-browser screenshot` + `safari-vision analyze`，預設 1500ms 間隔
- [x] 3.2 實作 Change detection：比較前後兩次 VLM 輸出，只在不同時 Push page change notifications
- [x] 3.3 實作 Temporary file cleanup：分析完成後刪除截圖暫存檔
- [x] 3.4 支援 `SB_CHANNEL_INTERVAL` 環境變數覆寫間隔

## 4. Reply Tool：雙向通訊（Execute safari-browser commands via reply tool、Return command output、Command validation）

- [x] 4.1 實作 `safari_action` MCP tool：ListToolsRequestSchema 註冊 tool schema（command + args）
- [x] 4.2 實作 CallToolRequestSchema handler：Execute safari-browser commands via reply tool，用 execFileSync 呼叫 safari-browser CLI
- [x] 4.3 實作 Command validation：白名單驗證 command 是合法的 safari-browser 子指令
- [x] 4.4 實作 Return command output：回傳 stdout 作為 tool result

## 5. Plugin 結構整合與啟動流程

- [x] 5.1 更新 `psychquant-claude-plugins/plugins/safari-browser/plugin.json`：加入 channel component 指向 `channel/channel.ts`
- [x] 5.2 更新 SKILL.md：加入 channel 使用說明和啟動方式
- [x] 5.3 在 `.mcp.json` 或 plugin manifest 中註冊 channel server

## 6. 測試與驗證

- [ ] 6.1 測試 safari-vision analyze：截圖 example.com → 驗證輸出包含 "Example Domain"
- [ ] 6.2 測試 channel server 單獨啟動：驗證 MCP handshake 成功
- [ ] 6.3 整合測試：`claude --dangerously-load-development-channels plugin:safari-browser@psychquant-claude-plugins` → 開啟網頁 → 驗證 Claude Code 收到 channel 事件
- [ ] 6.4 測試 reply tool：Claude Code 透過 safari_action 執行 click → 驗證頁面變化
