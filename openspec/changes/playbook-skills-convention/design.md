## Context

safari-browser 需要一個結構化機制來累積 site-specific 操作 playbook。經 `spectra-discuss` 評估四個模型（A 純 public / B 純 local / C layered custom dir / D Claude skills），使用者鎖定 **Model D（Claude Code skills，僅 target Claude Code）**。

現狀：
- safari-browser 主體 CLI 已成熟（41 Swift commands），但 agent 面對特定網站仍需重新摸索。
- 既有 plugin `psychquant-claude-plugins/plugins/safari-browser/` 已有 `skills/safari-browser/SKILL.md` 作為總入口 skill。
- 既有 spec `claude-plugin` 只規範 plugin 目錄結構存在，未規範「skills 目錄下可放什麼」。
- 既有 `references/agent-browser/` 和 `references/mas/` 是整個 repo clone，不是 safari-browser 自己的 playbook seed。
- browser-harness 的 `domain-skills/<site>/*.md`（~60 個站點）是 Chrome/CDP 慣例寫的，不能直接當 Safari playbook 使用。

約束：
- Plugin 目錄住在**另一個 repo**（`psychquant-claude-plugins`），與 safari-browser repo 分離。
- 使用者 workflow 以 Claude Code 為主，明確放棄跨 agent 中立。
- 不增加 Swift code、不新增 CLI subcommand。

## Goals / Non-Goals

**Goals:**

- 建立 playbook skill 的 **naming convention**，讓 agent 能以 description 自動選用。
- 定義 playbook skill 的 **frontmatter 契約**（必填欄位、`allowed-tools` 預設）。
- 定義 playbook SKILL.md 的 **結構 template**（ When to use / Preconditions / Steps / Gotchas / Verification）。
- 提供 **2 個 seed playbook skills** 作為後續貢獻的範本。
- 明確文件化 **user-local override 機制**（`~/.claude/skills/`），不需額外實作。
- 透過 `claude-plugin` spec delta 正式登記 plugin skills 目錄可容納 playbook skills。

**Non-Goals:**

- **不支援**其他 AI agent（Codex / Gemini CLI / Cursor）— 各自 skill 機制不同，本 change 不建平行結構或 converter。
- **不自動化** playbook 生成 — 本 change 定格式與 seed，未建 `safari-browser playbook new` 或類似 scaffolding。
- **不處理 plugin 膨脹問題** — 若未來 playbook 數量超過 50+ 需 split 成子 plugin，另開 proposal。
- **不更動 safari-browser Swift code** — 本 change 純文件 + skill 內容。
- **不處理 G4/G5** — Wave 1 另兩個 gap 各走獨立 proposal。
- **不設計 PR contribution flow** — public seed 的貢獻用既有 marketplace + GitHub PR 機制，不另外立流程。

## Decisions

### Naming convention: `safari-<site>-<action>`

Playbook skill 的目錄名統一採 `safari-<site>-<action>` 格式，例如 `safari-plaud-upload`、`safari-github-star`、`safari-icloud-login`。

**理由**：
- `safari-` 前綴區隔命名空間 — 避免與其他 plugin 的 skill 撞名（使用者可能同時裝 browser-harness plugin、agent-browser plugin）。
- `<site>` 是小寫 kebab-case 的域名片段（`plaud`, `github.com` → `github`, `icloud.com` → `icloud`）。
- `<action>` 是該網站的動作動詞（`upload`, `star`, `login`）。
- 結構化命名讓 `~/.claude/skills/` 清單仍可讀，避免純 adjective 混雜。

**替代方案**：
- `playbook-<site>-<action>`：更語意，但 `playbook-` 佔 9 字元且和其他 plugin skill 格式差太多，拒絕。
- `<site>/<action>/SKILL.md`（nested）：Claude Code skill loader 預期 flat dir，nested 不 work，拒絕。
- 不加前綴（純 `plaud-upload`）：容易與其他工具 skill 撞名（有些 plaud 處理工具已在其他 plugin 存在），拒絕。

### Frontmatter 契約

每個 playbook SKILL.md 必須含：

```yaml
---
name: safari-<site>-<action>
description: <一句話描述 trigger 條件與使用情境，≤200 字；明確提到 "Safari" 讓 Claude 不誤選>
allowed-tools:
  - Bash(safari-browser:*)
  - Bash(safari-browser *)
---
```

**理由**：
- `name` 必須 match dir 名（Claude Code 要求）。
- `description` 是 auto-surfacing 的唯一依據 — 寫得差等於 skill 不存在；規範「提到 Safari」避免跨 browser 工具混淆。
- `allowed-tools` 預設只 bind `safari-browser` CLI。如果 playbook 需要額外工具（`curl`、`jq`），在 skill 內額外宣告，不放 convention 預設。

**替代方案**：
- 繼承 main `safari-browser` skill 的 `allowed-tools`（不顯式宣告）：Claude Code skill 系統無 inheritance 機制，拒絕。
- 加 `version` / `author` frontmatter：Claude Code 不使用，保留 plugin 層級即可，拒絕。

### SKILL.md 結構 template

每個 playbook 的 body 分 6 段，順序固定：

1. **When to use** — 明確觸發情境（避免 description 不夠清楚時 agent 誤選）。
2. **Preconditions** — 需要的登入狀態、權限、檔案位置等。
3. **Steps** — 編號的 `safari-browser` 命令序列，每步驟附預期結果。
4. **Error handling** — 常見錯誤與分支處理。
5. **Verification** — 成功完成的判定方法（URL 變化、特定元素出現等）。
6. **Gotchas** — 該網站的 framework quirk、selector trap、反偵測。

**理由**：結構化讓 agent 讀取時容易抽取執行步驟，也讓使用者 review 時知道每個 playbook 的品質標準。

### Seed skills（初始 2 個）

- **`safari-plaud-upload`**：Plaud 音訊上傳流程（使用者已有實際 workflow 且已有 `plaud-transcriber` plugin 脈絡可參照）。
- **`safari-github-star`**：GitHub star repo 流程（前一個 session 演示過的互動，簡單可驗證）。

**理由**：
- 挑**已有使用者經驗**的網站，降低寫 playbook 時自己摸索的成本。
- 挑**一簡一繁**的 pair，示範 template 在短流程與含登入檢查流程的兩種極端適用性。

**替代方案**：
- 挑 3-5 個 seed：寫 playbook 成本高且每個還要驗證，Wave 1 先壓在 2 個，後續貢獻再擴。
- 不提供 seed，只寫 template：使用者沒例子很難照抄，拒絕。

### User-local override = `~/.claude/skills/` 原生支援

**不實作任何覆蓋邏輯**。Claude Code 原生支援使用者在 `~/.claude/skills/<name>/SKILL.md` 放 skill，Claude 會同時看到 plugin skill 與 user skill，依 description relevance 選擇。使用者可：

- 在 `~/.claude/skills/safari-my-internal-wiki/SKILL.md` 寫公司內部工具 playbook（plugin 版本不存在）。
- 在 `~/.claude/skills/safari-plaud-upload/SKILL.md` 寫自己的 Plaud playbook（與 plugin seed 同名，Claude 會視情境選其中之一）。

**理由**：
- 零實作成本。
- 使用者完全掌握自己的 skill；不會把私有內容意外 push 到 public plugin。
- Plugin 重裝不會覆蓋 user-local 版本。

**Trade-off**：如果 plugin 和 user-local 同名，Claude 的選擇規則（目前看起來是 description relevance + load order）不完全可控。這在 Wave 1 接受，若未來成為實際困擾另開 proposal 處理。

### Main skill 更新策略

在 `skills/safari-browser/SKILL.md` 最底端新增一個簡短 `## Playbooks` 段落：

- 一句話說明 playbook skills 的存在與命名 convention。
- 列出當前 seed playbooks（2 個）。
- 一行指示「想補自己的 playbook：寫在 `~/.claude/skills/safari-<site>-<action>/SKILL.md`」。

**不**把完整 template 或 contribution guide 塞進 main skill — 避免主 skill body 膨脹。完整規範放在新 spec `openspec/specs/playbook-skills/spec.md`。

## Risks / Trade-offs

- **[Plugin 膨脹]** 未來 50+ playbook 集中在同個 plugin，下載速度與 marketplace 清單雜亂。 → **Mitigation**：Non-Goal 已明確此 change 不處理；超過閾值時另開 proposal split 成 `safari-browser-playbooks` 子 plugin。

- **[Claude lock-in]** 本 change 明確放棄跨 agent 中立，未來若要支援 Codex / Gemini CLI 需重做結構或加 converter 層。 → **Mitigation**：使用者在 discuss 階段明確接受此 trade-off；future-proof 的成本 > 當前 concrete 好處。

- **[Convention drift]** 貢獻者不按 naming / frontmatter / template 寫，playbook 品質參差。 → **Mitigation**：spec 以 SHALL 描述硬性要求；未來可加 plugin-level linter（`plugin-tools:plugin-health` 可擴充檢查），但不在本 change scope。

- **[User-local 同名覆蓋不可控]** Plugin 與 user-local 同名 skill 時 Claude 選擇規則非 100% 可控。 → **Mitigation**：Decisions 已說明；當前接受此風險，未來若成實際困擾另開 proposal。

- **[Seed 過度擬合使用者個人 workflow]** Seed playbook 若寫得太貼近使用者個人帳號 / 設定，其他使用者拿到 plugin 後直接用會失敗。 → **Mitigation**：seed 寫作時強制通用化（不 hard-code 帳號、不假設 Pro plan、Preconditions 段明示所有前提），並在 tasks.md 的 seed 撰寫步驟加入「同儕 review」checkpoint。

- **[跨 repo coupling]** 本 change 的 artifact（spec）住 safari-browser repo，實作（skill files）住 psychquant-claude-plugins repo；兩者同步靠人工。 → **Mitigation**：tasks.md 明確標注每個動作的目標 repo；archive 該 change 時在 safari-browser repo 的 CLAUDE.md 補 cross-repo pointer，避免未來失聯。
