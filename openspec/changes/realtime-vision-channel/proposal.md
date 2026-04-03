## Why

safari-browser 目前是 one-shot CLI — Claude Code 每次要知道頁面狀態都得主動呼叫指令。這造成兩個問題：

1. **延遲**：Claude Code 不知道頁面何時載入完成、modal 何時出現、表單何時驗證失敗，只能盲目 `wait` 或反覆 polling
2. **Token 浪費**：如果傳截圖給 Claude 分析，每張圖 ~1000 tokens，無法高頻率使用

解決方案：利用 Claude Code 新的 **Channels** 功能（research preview），建立一個 channel plugin，在本地用 **Apple FastVLM**（CVPR 2025，85x faster TTFT）即時分析 Safari 截圖，只把文字摘要 push 到 Claude Code session。

## What Changes

### 新的子專案：safari-browser-channel

一個 Claude Code channel plugin，包含：

- **Channel MCP Server**（Bun/TypeScript）：實作 `claude/channel` capability，透過 stdio 與 Claude Code 通訊
- **Vision Worker**（Swift CLI）：用 FastVLM-0.5B CoreML 模型分析截圖，輸出文字摘要
- **Monitor Loop**：定期呼叫 `safari-browser screenshot` + FastVLM 分析，偵測頁面變化時 push 事件

### 資料流

```
Safari 頁面
    │
    ▼
safari-browser screenshot /tmp/sb-frame.png    （每 1-2 秒）
    │
    ▼
FastVLM-0.5B CoreML（Swift CLI）               （~6ms 推論）
    │  prompt: "What changed on this webpage? Be brief."
    │  output: "Login form submitted, redirecting to dashboard"
    ▼
Channel Server（Bun MCP）
    │  比較前後兩次 VLM 輸出，有變化才 push
    ▼
notifications/claude/channel → Claude Code
    <channel source="safari-vision" event="page_change">
      Login form submitted, redirecting to dashboard
    </channel>
```

### Claude Code 端的使用方式

```bash
# 啟動（development 階段）
claude --dangerously-load-development-channels plugin:safari-browser@psychquant-claude-plugins

# 正式發布後
claude --channels plugin:safari-browser@psychquant-claude-plugins
```

Claude Code 會即時收到頁面變化通知，可以自主決定下一步（不需要使用者指示 polling）。

### Reply Tool

Channel 也暴露 reply tool，讓 Claude Code 可以回傳 safari-browser 指令：

```
Claude Code → reply tool → channel server → safari-browser click "button.next"
```

## Non-Goals

- **替換現有 CLI** — channel 是補充，不是替代。safari-browser CLI 指令全部保留
- **雲端 VLM** — 不呼叫外部 API，完全本地推論
- **iOS 支援** — 只做 macOS（Safari + CoreML）
- **自動 permission bypass** — channel 不自動同意 Claude Code 的 permission prompt（除非使用者明確開啟 relay）
- **影片串流分析** — 用截圖 + diff，不做即時影片

## Capabilities

### New Capabilities

- `channel-server`: Bun MCP server 實作 claude/channel capability，push 頁面變化事件到 Claude Code
- `vision-worker`: Swift CLI 用 FastVLM CoreML 分析截圖，輸出簡短文字摘要
- `monitor-loop`: 定期截圖 + VLM 分析 + 變化偵測 + push 邏輯
- `reply-tool`: Claude Code 可透過 channel 回傳 safari-browser 指令執行

### Modified Capabilities

（無）

## Impact

- 新增子專案：`channel/`（或獨立 repo `safari-browser-channel/`）
- 新增檔案：`channel/channel.ts`（MCP server）、`channel/vision-worker/`（Swift CLI + FastVLM）、`channel/plugin.json`
- 修改：`psychquant-claude-plugins/plugins/safari-browser/` 的 plugin.json（加 channel component）
- 依賴：Bun、`@modelcontextprotocol/sdk`、FastVLM CoreML model、safari-browser CLI
