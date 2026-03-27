## 1. safari-browser repo — Git 與建置

- [x] 1.1 更新 `.gitignore`（Git repository initialized）：加入 `.build/`、`.swiftpm/`、`Package.resolved`
- [x] 1.2 建立 `Makefile`：Build via Makefile（`swift build -c release`）、Install via Makefile（build + cp to `~/bin/safari-browser`）、Clean via Makefile（rm -rf `.build/`）
- [x] 1.3 建立 `README.md`：專案說明、安裝方式（`make install`）、完整指令清單（32 個子指令）、與 agent-browser 的比較
- [ ] 1.4 `git init` + 初始 commit + 建立 GitHub private repo `PsychQuant/safari-browser` + push

## 2. Claude Code Plugin

- [ ] 2.1 建立 Plugin structure in psychquant-claude-plugins：`plugins/safari-browser/plugin.json`
- [ ] 2.2 建立 SKILL.md teaches CLI usage and routing：`plugins/safari-browser/skills/safari-browser/SKILL.md`，含 trigger 條件（需登入的網站自動化）、safari-browser vs agent-browser routing 邏輯、完整指令參考、使用範例
- [ ] 2.3 建立 SessionStart hook checks CLI availability：`plugins/safari-browser/hooks/hooks.json` + `hooks/check-cli.sh`，檢查 binary 是否存在，不存在則輸出 build 指令提示
- [ ] 2.4 在 psychquant-claude-plugins 做 commit + push
