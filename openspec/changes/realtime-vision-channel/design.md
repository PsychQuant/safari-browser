## Context

safari-browser 是 one-shot CLI，Claude Code 必須主動呼叫才能知道頁面狀態。Claude Code Channels（research preview, v2.1.80+）允許 MCP server push 事件到 running session。Apple FastVLM（CVPR 2025）在 M4 Max 上可達 ~6ms TTFT，適合即時截圖分析。

三個技術整合：safari-browser CLI（截圖）+ FastVLM CoreML（視覺分析）+ Channels MCP（push 到 Claude Code）。

## Goals / Non-Goals

**Goals:**

- Claude Code 即時收到頁面變化的文字描述（不需 polling）
- 完全本地推論，不呼叫外部 API
- Token 效率：只傳文字摘要（~50 tokens），不傳圖片（~1000 tokens）
- Claude Code 可透過 reply tool 回傳 safari-browser 指令

**Non-Goals:**

- 替換 CLI 指令（channel 是補充）
- 影片串流分析（用截圖 + diff）
- iOS 支援
- 自動 permission relay（除非使用者明確開啟）

## Decisions

### 三層架構：Channel Server + Vision Worker + Monitor Loop

```
┌─────────────────────────────────────────────────────┐
│ Channel Server (Bun, MCP over stdio)                │
│                                                     │
│  ┌───────────────┐    ┌──────────────────────────┐  │
│  │ Monitor Loop  │───▶│ Vision Worker (Swift CLI) │  │
│  │ (setInterval) │    │ FastVLM-0.5B CoreML       │  │
│  │               │◀───│                           │  │
│  └───────┬───────┘    └──────────────────────────┘  │
│          │                                          │
│          ▼                                          │
│  notifications/claude/channel ──▶ Claude Code       │
│                                                     │
│  reply tool ◀── Claude Code                         │
│     │                                               │
│     ▼                                               │
│  safari-browser <command> (execFile)                │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**為什麼三層不合一？**
- Channel server 必須是 MCP over stdio（Claude Code 限制）→ Bun/Node
- VLM 是 Swift MLX → 必須是 Swift CLI
- 分離讓各層可獨立測試和替換

### Vision Worker：Swift CLI + MLXVLM（mlx-swift-lm）

使用 Apple 的 `mlx-swift-lm` package 中的 MLXVLM 模組。支援 Qwen2.5-VL、Qwen3-VL、SmolVLM、Gemma-3 等多種 VLM。

```swift
import MLXVLM
import MLXLMHuggingFace
import MLXLMTokenizers

let model = try await loadModel(
    using: TokenizersLoader(),
    id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
)
let session = ChatSession(model)
let answer = try await session.respond(
    to: "What changed on this webpage?",
    image: .url(URL(fileURLWithPath: "/tmp/sb-frame.png"))
)
print(answer)
```

```bash
# CLI 介面
safari-vision analyze /tmp/frame.png "What changed on this webpage?"

# 輸出：純文字（stdout）
"Login form submitted, page redirecting to dashboard"
```

選 MLXVLM（mlx-swift-lm）的原因：
- Apple 官方 MLX Swift package，原生 Apple Silicon 加速
- 支援多種 VLM（Qwen2.5-VL-3B 4bit、SmolVLM 等），可切換
- Swift 整合，跟 safari-browser 同一技術棧
- ChatSession API 簡潔，幾行就能推論
- 模型自動從 Hugging Face 下載並 cache

預設模型：`mlx-community/Qwen2.5-VL-3B-Instruct-4bit`（4bit 量化，~2GB RAM）
模型 cache：Hugging Face Hub cache 目錄（`~/.cache/huggingface/hub/`）

### Monitor Loop：智慧 diff

不是每秒都 push — 只在 VLM 輸出與上一次不同時才 push：

```typescript
// 使用 execFile 避免 shell injection（不使用 exec）
import { execFileSync } from "child_process"

let lastDescription = ""
setInterval(async () => {
    execFileSync("safari-browser", ["screenshot", "/tmp/sb-frame.png"])
    const desc = execFileSync("safari-vision", ["analyze", "/tmp/sb-frame.png",
        "Describe the current state of this webpage in one sentence."])
        .toString().trim()
    if (desc !== lastDescription) {
        lastDescription = desc
        await mcp.notification({
            method: "notifications/claude/channel",
            params: {
                content: desc,
                meta: { event: "page_change", timestamp: Date.now().toString() }
            }
        })
    }
}, 1500)  // 每 1.5 秒檢查一次
```

### Reply Tool：雙向通訊

Claude Code 可以透過 channel 的 reply tool 執行 safari-browser 指令：

```typescript
// Claude calls: reply({ command: "click", args: ["button.submit"] })
// Channel server executes: execFileSync("safari-browser", ["click", "button.submit"])
```

這讓 Claude Code 形成完整的 observe → decide → act loop。

### Plugin 結構

```
psychquant-claude-plugins/plugins/safari-browser/
├── plugin.json          (更新：加 channel component)
├── skills/
│   └── safari-browser/SKILL.md
├── hooks/
│   └── hooks.json + check-cli.sh
└── channel/
    ├── channel.ts       (Bun MCP server)
    ├── package.json     (依賴 @modelcontextprotocol/sdk)
    └── bin/
        └── safari-vision  (Swift CLI binary)
```

### 啟動流程

```bash
# 1. 確保 safari-browser CLI 已安裝
safari-browser get title

# 2. 確保 FastVLM model 已下載
safari-vision setup  # 首次下載 CoreML model

# 3. 啟動 Claude Code with channel
claude --dangerously-load-development-channels plugin:safari-browser@psychquant-claude-plugins
```

## Risks / Trade-offs

- **[FastVLM 模型品質]** → 0.5B 模型可能對複雜頁面描述不夠精確。Mitigation：用具體的 prompt（"List all visible buttons and their text"）而非開放式描述；必要時升級到 1.5B
- **[CoreML 編譯時間]** → 首次載入 CoreML model 可能需要數分鐘編譯。Mitigation：預編譯 + cache 到 `~/.safari-browser/models/`
- **[Channels research preview]** → API 可能變動。Mitigation：channel server 薄薄一層，易於適應
- **[截圖頻率 vs 系統負載]** → 每 1.5 秒截圖 + VLM 推論。M4 Max 128GB 應該不是問題，但低配 Mac 可能吃力。Mitigation：可調間隔，`--interval` flag
- **[safari-browser sandbox 限制]** → 在 Claude Code sandbox 中 `safari-browser` 可能被 kill（codesign 問題）。Mitigation：已修（`make install` 自動 codesign）
- **[Privacy]** → 截圖可能包含敏感資訊。Mitigation：完全本地推論，截圖用完即刪，VLM 輸出是摘要文字
