## Why

`safari-browser` 與 `agent-browser`(Chromium / Puppeteer)在使用者環境已並存,Playwright 也是常見第三個 backend。但 `playbook-skills` 既有 frontmatter 規範(`name` / `description` / `allowed-tools` 三鍵,且 `description` 強制提「Safari」)假設了單一 backend,沒有任何機制讓 playbook **declarative 宣告**自己需要 / 支援哪個 browser backend。後果:

- harness 與 agent 無從根據 playbook 需求自動挑對 backend
- 跨 backend 的 playbook(例:同一個目標站 Chrome / Safari 都跑得了)無法表達 preference
- 「description MUST mention Safari」這條把 disambiguation 責任放在 free text,跨 backend 擴展時會自我矛盾(`backend: chrome` 的 playbook 怎麼描述?)

加上 `backend:` metadata 讓**意圖留在 declarative frontmatter**,而不是分散在文字描述或 runtime 推論。

## What Changes

- **新增 `backend:` 欄位** 進 playbook frontmatter schema:
  - 單值或陣列(preference list,順序即優先序)
  - 允許值:`safari` / `chrome` / `playwright` / `any`
  - 範例:`backend: safari`、`backend: [safari, chrome]`、`backend: any`
- **新增 optional `backend_reason:` 欄位**:human-readable 記錄為何選此 backend(例:`"Apple session + anti-detection"`),供未來決策審視用,不影響 loader 行為
- **BREAKING** 鬆綁 `Playbook skill frontmatter` 既有規則:
  - frontmatter 鍵集從「exactly `name` / `description` / `allowed-tools`」改為「至少含此三鍵 + 允許 `backend` 與 `backend_reason`」
  - 「`description` MUST mention 'Safari'」改為與 `backend` 一致的條件式規則:`backend: safari` 時 MUST 提 Safari;其他 backend 時 MUST 提對應 backend 名以利 disambiguation
- **新增遷移條款**:既有 playbook 未宣告 `backend:` 時 SHALL 視為 `backend: safari`(向後相容預設值),不需強制 retro-update

## Non-Goals

- **不實作 routing engine**:本 change 只定義 declarative metadata schema。Harness 怎麼根據 metadata 挑 backend、fallback 邏輯、capability detection 等屬於 consumer-side concern,留給後續 change
- **不修改 plugin repo seed playbooks**:`safari-plaud-upload`、`safari-github-star` 等既有 seed 套上 `backend:` 屬於 downstream 工作,在 `psychquant-claude-plugins` repo 另開 PR
- **不建立 decision advisor / browser-which skill**:`tool-finder` 的 browser 子 skill 是獨立 deliverable(對話中標記為 C 路線),不在此 change scope
- **不擴張 backend 值域**:`webdriver` / `selenium` / `firefox` / `edge` 等不納入。值域刻意小、明確列舉,未來新增 backend 走另一個 change 顯式擴張
- **不變更目錄命名規範**:`safari-<site>-<action>` 命名暫時保留(即使 backend 改成 chrome)。重新命名規範屬於 follow-up 設計議題

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `playbook-skills`:frontmatter contract 新增 `backend` / `backend_reason` 欄位、鬆綁鍵集封閉性、條件化 description 規則、加遷移預設值

## Impact

- **Affected specs**:`playbook-skills`(modified — 主要是 `Playbook skill frontmatter` requirement 的 delta)
- **Affected code**:
  - `openspec/specs/playbook-skills/spec.md`(此 repo,規範來源)
  - **下游(本 change out-of-scope,僅供 reference)**:
    - `psychquant-claude-plugins/plugins/safari-browser/skills/CONTRIBUTING-PLAYBOOKS.md`(後續 PR 同步)
    - `psychquant-claude-plugins/plugins/safari-browser/skills/safari-plaud-upload/SKILL.md`(後續 PR retro 套 metadata)
    - `psychquant-claude-plugins/plugins/safari-browser/skills/safari-github-star/SKILL.md`(後續 PR retro 套 metadata)
- **Breaking change risk**:鬆綁「鍵集 exactly」規則屬於放寬,既有 playbook 不需更動仍 valid(透過 `backend: safari` 遷移預設值)。description 規則的條件化也只在 `backend: safari` 時跟舊規則一致,broader backend 才需新規則 — 既有 playbook 都是 safari,不受影響
