## ADDED Requirements

### Requirement: Plugin skills directory hosts main skill plus playbook skills

The `psychquant-claude-plugins/plugins/safari-browser/skills/` directory SHALL be permitted to contain, in addition to the main `safari-browser/` skill, one or more playbook skill directories that conform to the `playbook-skills` capability. Each playbook skill MUST be a sibling of the main skill (flat layout, no nesting).

#### Scenario: Plugin with only main skill

- **WHEN** a release of the plugin contains only `skills/safari-browser/SKILL.md`
- **THEN** the plugin is valid; playbook skills are optional

#### Scenario: Plugin with main skill plus playbooks

- **WHEN** a release of the plugin contains `skills/safari-browser/SKILL.md`, `skills/safari-plaud-upload/SKILL.md`, and `skills/safari-github-star/SKILL.md`
- **THEN** the plugin is valid and all skills are loaded by Claude Code

#### Scenario: Nested playbook layout is invalid

- **WHEN** a release of the plugin contains `skills/playbooks/plaud-upload/SKILL.md` (nested)
- **THEN** the plugin MUST be rejected; playbook skills must live at the same level as the main skill
