## 1. 規範驗證

- [x] 1.1 [P] `Playbook skill frontmatter` MODIFIED requirement 與其 8 個 scenarios 通過 spectra analyzer 檢查,沒有任何 Critical 或 Warning level 的 finding(包括 cross-reference 與 normative 用詞檢查)— 驗證方式:執行 `spectra analyze playbook-backend-metadata --json` 並確認 critical/warning 陣列為空
- [x] 1.2 [P] 整份 change(proposal + spec delta)通過 spectra 結構性驗證 — 驗證方式:執行 `spectra validate playbook-backend-metadata` 並確認 exit code 為 0、無 schema 違反訊息

## 2. 既有 playbook 向後相容性

- [x] 2.1 [P] 既有的兩個 seed playbook(位於 `psychquant-claude-plugins/plugins/safari-browser/skills/safari-plaud-upload/SKILL.md` 與 `safari-github-star/SKILL.md`)在沒有宣告 `backend` 欄位的情況下,根據新的 `Playbook skill frontmatter` 規範套用 `backend: safari` 預設值後仍為 valid — 驗證方式:讀取兩份 SKILL.md frontmatter,逐項對照 modified requirement 的每條規則(`name` 與目錄名一致、`description` 含 "Safari"、`allowed-tools` 至少含 `Bash(safari-browser:*)` 與 `Bash(safari-browser *)`、無禁用鍵),並把對照結果寫入此 task 的 commit message 作為 verification record

## 3. 跨 repo follow-up 邊界記錄

- [x] 3.1 在此 change 的 archive commit message 中明確記錄下游 follow-up 工作的 out-of-scope 邊界 — 行為:archive commit 後讀者能立即看到「plugin repo 的 CONTRIBUTING-PLAYBOOKS.md 更新、seed playbooks retro 套 `backend: safari`、tool-finder 新增 `which-browser` sub-skill」這三項屬於後續 separate PR;驗證方式:檢視 archive commit message 第二段須含此三項 follow-up 條列,且未誤把它們列入本 change 的 deliverable(draft 已寫入 `archive-commit-message.md`)
