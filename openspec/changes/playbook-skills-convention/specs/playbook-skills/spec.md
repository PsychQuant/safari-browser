## ADDED Requirements

### Requirement: Playbook skill directory naming

Each site-specific playbook SHALL be a Claude Code skill living in `psychquant-claude-plugins/plugins/safari-browser/skills/` as a sibling of the main `safari-browser` skill. The directory name SHALL follow the pattern `safari-<site>-<action>`, where `<site>` is the lowercase kebab-case fragment of the target website's domain and `<action>` is a lowercase verb describing the operation.

#### Scenario: Valid playbook directory name

- **WHEN** a contributor creates a playbook for uploading audio to Plaud
- **THEN** the directory is `plugins/safari-browser/skills/safari-plaud-upload/` containing `SKILL.md`

#### Scenario: Invalid playbook directory name is rejected

- **WHEN** a contributor submits a playbook in `plugins/safari-browser/skills/plaud-upload/` (missing `safari-` prefix)
- **THEN** reviewers SHALL reject the contribution and request renaming to `safari-plaud-upload/`

#### Scenario: Nested directory layout is forbidden

- **WHEN** a contributor places a playbook at `plugins/safari-browser/skills/plaud/upload/SKILL.md`
- **THEN** Claude Code's skill loader MUST NOT discover it, and reviewers SHALL reject the contribution

---

### Requirement: Playbook skill frontmatter

Each playbook `SKILL.md` SHALL begin with YAML frontmatter containing exactly these keys: `name`, `description`, and `allowed-tools`. The `name` value MUST match the enclosing directory name exactly. The `description` value MUST NOT exceed 200 characters, MUST mention "Safari" explicitly to disambiguate from Chrome-based browser automation tools, and MAY contain trigger phrases or use-case phrases after an initial action clause. The `allowed-tools` value SHALL include at minimum `Bash(safari-browser:*)` and `Bash(safari-browser *)`.

#### Scenario: Well-formed playbook frontmatter

- **WHEN** a playbook `safari-plaud-upload/SKILL.md` declares `name: safari-plaud-upload`, a description mentioning "Safari" and "Plaud upload", and `allowed-tools: [Bash(safari-browser:*), Bash(safari-browser *)]`
- **THEN** Claude Code loads the skill and auto-surfaces it when the user asks about uploading to Plaud

#### Scenario: Frontmatter name mismatch is a defect

- **WHEN** a playbook `safari-plaud-upload/SKILL.md` declares `name: plaud-upload` (missing prefix)
- **THEN** the skill is invalid and MUST be corrected before the playbook is accepted

#### Scenario: Description without "Safari" keyword is a defect

- **WHEN** a playbook's description does not contain the word "Safari"
- **THEN** the playbook is invalid because it risks being auto-surfaced when the user is using a Chrome-based tool

#### Scenario: Extra allowed-tools entries are permitted

- **WHEN** a playbook needs additional commands (e.g., `Bash(curl:*)`)
- **THEN** the playbook MAY append those entries beyond the required minimum

---

### Requirement: Playbook SKILL.md body structure

Each playbook `SKILL.md` body SHALL contain six sections in the following fixed order, each introduced by a level-2 heading: `## When to use`, `## Preconditions`, `## Steps`, `## Error handling`, `## Verification`, `## Gotchas`.

#### Scenario: Complete playbook body

- **WHEN** a reviewer reads `safari-plaud-upload/SKILL.md`
- **THEN** the six headings appear in the specified order and each contains non-empty content

#### Scenario: Missing section fails review

- **WHEN** a playbook omits `## Verification` or places `## Steps` before `## Preconditions`
- **THEN** the playbook MUST be corrected before acceptance

---

### Requirement: Seed playbook skills exist

The `psychquant-claude-plugins/plugins/safari-browser/skills/` directory SHALL contain at least two seed playbook skills that conform to all playbook naming, frontmatter, and structure requirements. The initial seeds SHALL be `safari-plaud-upload` and `safari-github-star`.

#### Scenario: Seeds are present after change applied

- **WHEN** the change `playbook-skills-convention` is archived and the plugin is published
- **THEN** `skills/safari-plaud-upload/SKILL.md` and `skills/safari-github-star/SKILL.md` exist and pass all convention requirements

#### Scenario: Seeds are generalized, not personal

- **WHEN** a new user with no prior account configuration installs the plugin and follows the seed playbook
- **THEN** the playbook either succeeds using only documented preconditions, or it fails with a Preconditions-section error the user can resolve without reading the playbook author's mind

---

### Requirement: User-local playbook override via native Claude Code mechanism

A user SHALL be able to place a personal playbook at `~/.claude/skills/safari-<site>-<action>/SKILL.md` that conforms to the same naming, frontmatter, and structure requirements as plugin-hosted playbooks. The system SHALL NOT implement any custom override, merging, or precedence logic beyond what Claude Code natively provides.

#### Scenario: User creates a private playbook for an internal site

- **WHEN** a user writes `~/.claude/skills/safari-internal-wiki-login/SKILL.md` for a company-internal wiki not present in the plugin
- **THEN** Claude Code auto-surfaces it when the user asks about logging into the internal wiki, without any change to the plugin

#### Scenario: User and plugin playbooks share a name

- **WHEN** both `~/.claude/skills/safari-plaud-upload/SKILL.md` and the plugin's `safari-plaud-upload` skill exist
- **THEN** Claude Code's native skill loading selects one based on its built-in rules (description relevance, load order); this specification does not impose a custom precedence

---

### Requirement: Main safari-browser skill references playbooks

The main `psychquant-claude-plugins/plugins/safari-browser/skills/safari-browser/SKILL.md` SHALL include a `## Playbooks` section that: (a) describes the `safari-<site>-<action>` naming convention in one sentence, (b) lists the current seed playbook names, and (c) documents the user-local override path at `~/.claude/skills/safari-<site>-<action>/SKILL.md`.

#### Scenario: Main skill exposes playbook entry point

- **WHEN** a user reads the main `safari-browser` skill
- **THEN** the `## Playbooks` section is visible near the end of the document and contains the naming convention, seed list, and override path

#### Scenario: Main skill does not duplicate the full convention

- **WHEN** a reviewer compares the main skill's `## Playbooks` section with `openspec/specs/playbook-skills/spec.md`
- **THEN** the main skill contains only the summary described above; the full convention lives in the spec
