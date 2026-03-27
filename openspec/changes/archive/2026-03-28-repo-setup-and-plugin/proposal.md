## Why

safari-browser 目前只有 source code 和編譯好的 binary，但沒有 git repo、沒有安裝機制、也沒有 Claude Code plugin 讓 Claude 知道何時使用。需要完成三件事：(1) 初始化 git repo 並建立 GitHub repo，(2) 建立標準化的安裝機制，(3) 在 psychquant-claude-plugins 建立 plugin，包含 skill 和自動安裝 hook。

## What Changes

### safari-browser repo（本 repo）
- 初始化 git repo，建立 GitHub private repo（PsychQuant/safari-browser）
- 更新 `.gitignore` 加入 `.build/`、`.swiftpm/`、`Package.resolved`
- 新增 `Makefile`：`make build`、`make install`、`make clean`
- 新增 `README.md`：說明用途、安裝方式、完整指令清單
- 初始 commit + push

### psychquant-claude-plugins（外部 repo）
- 新增 `plugins/safari-browser/` 目錄
- 建立 `plugin.json`
- 建立 `skills/safari-browser/SKILL.md`：教 Claude 什麼時候用 safari-browser（需登入的網站）vs agent-browser（不需登入 / CI / headless），附完整指令參考
- 建立 `hooks/hooks.json` + `hooks/check-cli.sh`：SessionStart 時檢查 `~/bin/safari-browser` 是否存在，不存在則提示從 source build（`cd ~/Developer/safari-browser && make install`）

## Non-Goals

- GitHub Release / pre-built binary 下載 — 目前只有自己用，從 source build 即可
- MCP server — safari-browser 是 CLI 工具，不是 MCP server，透過 Bash 呼叫
- 自動更新機制 — 手動 `git pull && make install`

## Capabilities

### New Capabilities

- `build-and-install`: Makefile 建置與安裝機制
- `claude-plugin`: Claude Code plugin（skill + hooks）在 psychquant-claude-plugins

### Modified Capabilities

（無）

## Impact

- 本 repo 新增：`Makefile`、`README.md`，修改 `.gitignore`
- 外部 repo 新增：`/Users/che/Developer/psychquant-claude-plugins/plugins/safari-browser/`（plugin.json、skills/、hooks/）
