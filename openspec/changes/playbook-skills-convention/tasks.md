## 1. Setup

- [x] 1.1 Confirm current plugin structure in `psychquant-claude-plugins/plugins/safari-browser/skills/` and create working branch `playbook-skills-convention`

## 2. Convention Documentation

- [x] 2.1 Write `skills/CONTRIBUTING-PLAYBOOKS.md` capturing the Naming convention: `safari-<site>-<action>`, the Frontmatter 契約 (name match, Safari-mentioning description, allowed-tools minimum), the SKILL.md 結構 template six-section structure, and the rule that Plugin skills directory hosts main skill plus playbook skills without nesting

## 3. Seed skills（初始 2 個）

- [x] 3.1 [P] Write `skills/safari-plaud-upload/SKILL.md` with valid frontmatter and six ordered sections, satisfying Playbook skill directory naming, Playbook skill frontmatter, Playbook SKILL.md body structure, and generalized preconditions per Seed playbook skills exist
- [x] 3.2 [P] Write `skills/safari-github-star/SKILL.md` with valid frontmatter and six ordered sections, including login-branch logic in Preconditions, satisfying the same four requirements

## 4. Main skill 更新策略

- [x] 4.1 Append a `## Playbooks` section to `skills/safari-browser/SKILL.md` containing only the convention sentence, the seed list, and the override path, per Main safari-browser skill references playbooks (summary only — full convention stays in the spec)

## 5. User-local override = `~/.claude/skills/` 原生支援

- [x] 5.1 Within the `## Playbooks` section from 4.1, include the example path `~/.claude/skills/safari-<site>-<action>/SKILL.md` to document User-local playbook override via native Claude Code mechanism; confirm no custom precedence logic is introduced anywhere in the plugin

## 6. Cross-Repo Documentation

- [x] 6.1 [P] Update `safari-browser` repo's `CLAUDE.md` under the Plugin block with a pointer to `openspec/specs/playbook-skills/spec.md` and the plugin seed locations (Cross-repo coupling risk mitigation)

## 7. Verification

- [x] 7.1 Self-review each seed against every scenario in `openspec/specs/playbook-skills/spec.md` — covers Playbook skill directory naming through Main safari-browser skill references playbooks
- [ ] 7.2 In a fresh Claude Code session with the plugin installed, ask Claude to "upload audio to Plaud via Safari" and confirm `safari-plaud-upload` auto-surfaces (validates the Frontmatter 契約 description trigger and Seed playbook skills exist)
- [ ] 7.3 In a fresh Claude Code session, ask Claude to "star the browser-use/browser-harness repo via Safari" and confirm `safari-github-star` auto-surfaces
- [ ] 7.4 Create a dummy `~/.claude/skills/safari-internal-test-login/SKILL.md` with minimal valid content and confirm Claude discovers it, validating User-local playbook override via native Claude Code mechanism end-to-end

## 8. Deploy

- [ ] 8.1 Run `/plugin-tools:plugin-update safari-browser` to sync marketplace version and push the plugin changes
- [ ] 8.2 Install the updated plugin in a clean test session and rerun 7.2 and 7.3 against the deployed version
- [ ] 8.3 Run `/idd-update #32` on the safari-browser repo to mark Wave 1 G1 progress in the tracking issue
