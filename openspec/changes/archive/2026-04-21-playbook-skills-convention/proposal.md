## Why

safari-browser 作為 CLI 工具解決了 Safari automation 的底層機制，但 agent 要在特定網站（Plaud、GitHub、iCloud 等）完成特定流程時，還是得每次重新摸索 —— 找 selector、試 snapshot refs、猜互動順序。這些「site-specific 操作流程」需要一個可累積、可分享、可被 Claude Code 自動 surface 的容器。

browser-harness 用 `domain-skills/<site>/*.md` 解決，但那是 Chrome-centric 自訂格式。safari-browser 既然已經有 Claude Code plugin（`psychquant-claude-plugins/plugins/safari-browser/`），直接複用 Claude Code skills 機制是最小代價：免費拿到 auto-surfacing（依 description 載入）、plugin 版本化、user-local override（`~/.claude/skills/`）。

這個 change 建立 **playbook skills 的格式與命名契約**，讓後續每個網站的 playbook 都能一致地被 agent 理解與使用者維護。

## What Changes

- **新 capability `playbook-skills`**：定義 playbook skill 的 naming、frontmatter、結構、user-local override 行為。
- **修改 capability `claude-plugin`**：明確新增「plugin `skills/` 可容納 playbook skills，每個 playbook 是獨立 skill dir」的 requirement。
- **seed skills**：在 `psychquant-claude-plugins/plugins/safari-browser/skills/` 新增 2 個示範 playbook：
  - `safari-plaud-upload/` — Plaud 音訊上傳流程
  - `safari-github-star/` — GitHub star repo 流程
- **更新 main skill**：`psychquant-claude-plugins/plugins/safari-browser/skills/safari-browser/SKILL.md` 加一個「Playbooks」段落，簡短介紹 convention 並指向 seed skills。
- **文件化 user-local override**：在 main skill 的 Playbooks 段落說明使用者可在 `~/.claude/skills/my-site-<action>/SKILL.md` 寫自己的 playbook 覆蓋或補強 plugin 提供的版本。

## Capabilities

### New Capabilities

- `playbook-skills`: 定義 site-specific playbook 作為 Claude Code skills 的格式與行為契約，含 naming convention、frontmatter requirements、結構 template、與 user-local override 的互動。

### Modified Capabilities

- `claude-plugin`: 在既有「plugin structure」requirement 之外，新增「plugin skills 目錄下可容納 playbook skills，每個 playbook 為獨立 skill dir，與 main `safari-browser` skill 同層」的 requirement。

## Impact

- **Affected specs**:
  - 新增 `openspec/specs/playbook-skills/spec.md`
  - 修改 `openspec/specs/claude-plugin/spec.md`（delta：plugin skills 目錄 layout 擴充）
- **Affected code**（均在 `psychquant-claude-plugins` repo，非 safari-browser 本體）：
  - 新增 `plugins/safari-browser/skills/safari-plaud-upload/SKILL.md`
  - 新增 `plugins/safari-browser/skills/safari-github-star/SKILL.md`
  - 更新 `plugins/safari-browser/skills/safari-browser/SKILL.md`（新增 Playbooks 段落）
- **Affected docs**:
  - 更新 safari-browser repo 的 `CLAUDE.md`（補 Playbook convention section 與 cross-repo link）
- **Affected tooling**: 無。不動 Swift code、無新 CLI subcommand、不改 build pipeline。
- **Cross-agent compatibility**: **放棄**。本 proposal 明確只 target Claude Code；其他 agent（Codex / Gemini CLI / Cursor）不在範圍內，未來若需要可另開 proposal 定 converter 或平行結構。
