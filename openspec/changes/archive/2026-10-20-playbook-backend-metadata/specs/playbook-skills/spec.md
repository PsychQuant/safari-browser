## MODIFIED Requirements

### Requirement: Playbook skill frontmatter

Each playbook `SKILL.md` SHALL begin with YAML frontmatter containing at minimum these keys: `name`, `description`, and `allowed-tools`. Frontmatter SHALL also accept the optional keys `backend` and `backend_reason` defined below. Keys outside this enumerated set SHALL NOT appear in playbook frontmatter.

The `name` value MUST match the enclosing directory name exactly.

The `description` value MUST NOT exceed 200 characters. The disambiguation requirement on `description` is conditional on `backend`:

- When `backend` is `safari`, omitted (defaulting to `safari`), or an array whose only entry is `safari`, the description MUST mention "Safari" explicitly.
- When `backend` is `chrome`, or an array whose only entry is `chrome`, the description MUST mention "Chrome" explicitly.
- When `backend` is `playwright`, or an array whose only entry is `playwright`, the description MUST mention "Playwright" explicitly.
- When `backend` is `any`, or an array with more than one entry, the description MUST contain a generic browser-automation disambiguator phrase such as "browser automation", "via browser", or "browser-driven".

The `description` MAY contain trigger phrases or use-case phrases after the initial action clause.

The `allowed-tools` value SHALL include the tool invocations required by the playbook's declared backend. Playbooks whose `backend` is `safari`, omitted, or an array containing `safari` SHALL include at minimum `Bash(safari-browser:*)` and `Bash(safari-browser *)`.

The optional `backend` value SHALL be either a single string or an array of strings drawn from the closed set `safari`, `chrome`, `playwright`, `any`. When provided as an array, the order SHALL indicate preference, with the first entry being the most preferred backend. When `backend` is omitted, the playbook SHALL be interpreted exactly as if `backend: safari` had been declared (backward-compatibility default).

The optional `backend_reason` value SHALL be a human-readable string explaining why the declared backend is required (for example, authenticated Apple session, anti-detection requirement, cross-OS compatibility). The `backend_reason` value is informational and SHALL NOT affect skill loading or routing.

#### Scenario: Well-formed playbook frontmatter with default backend

- **WHEN** a playbook `safari-plaud-upload/SKILL.md` declares `name: safari-plaud-upload`, a description mentioning "Safari" and "Plaud upload", `allowed-tools: [Bash(safari-browser:*), Bash(safari-browser *)]`, and omits the `backend` key
- **THEN** Claude Code loads the skill, treats it as `backend: safari` by default, and auto-surfaces it when the user asks about uploading to Plaud

#### Scenario: Frontmatter name mismatch is a defect

- **WHEN** a playbook `safari-plaud-upload/SKILL.md` declares `name: plaud-upload` (missing prefix)
- **THEN** the skill is invalid and MUST be corrected before the playbook is accepted

#### Scenario: Description without backend-appropriate disambiguator is a defect

- **WHEN** a playbook declares `backend: safari` but its description does not contain the word "Safari", or declares `backend: chrome` but does not contain "Chrome", or declares `backend: [safari, chrome]` but contains neither a generic browser-automation phrase nor both backend names
- **THEN** the playbook is invalid and MUST be corrected before acceptance

##### Example: backend-to-description disambiguator matrix

| `backend` value         | description MUST contain                                              |
| ----------------------- | --------------------------------------------------------------------- |
| omitted                 | "Safari"                                                              |
| `safari`                | "Safari"                                                              |
| `chrome`                | "Chrome"                                                              |
| `playwright`            | "Playwright"                                                          |
| `[safari]`              | "Safari"                                                              |
| `[chrome]`              | "Chrome"                                                              |
| `[safari, chrome]`      | "browser automation" / "via browser" / "browser-driven" (any of)      |
| `any`                   | "browser automation" / "via browser" / "browser-driven" (any of)      |

#### Scenario: Extra allowed-tools entries are permitted

- **WHEN** a playbook needs additional commands such as `Bash(curl:*)`
- **THEN** the playbook MAY append those entries beyond the required minimum

#### Scenario: Backend omitted defaults to safari

- **WHEN** a playbook's frontmatter has no `backend` key
- **THEN** every requirement that references `backend` SHALL evaluate the playbook as if `backend: safari` were declared, including the description disambiguation and `allowed-tools` rules

#### Scenario: Backend declared as a single string

- **WHEN** a playbook declares `backend: chrome`
- **THEN** the playbook is valid provided its description mentions "Chrome" and its `allowed-tools` includes the Chrome-backend tool invocations required by its steps

#### Scenario: Backend declared as a preference list

- **WHEN** a playbook declares `backend: [safari, chrome]`
- **THEN** the playbook is valid provided its description contains a generic browser-automation disambiguator, and the harness SHALL interpret `safari` as the preferred backend and `chrome` as the acceptable fallback

#### Scenario: Invalid backend value is rejected

- **WHEN** a playbook declares `backend: firefox`, `backend: webdriver`, `backend: selenium`, or any value outside the closed set `{safari, chrome, playwright, any}`
- **THEN** the playbook is invalid and MUST be corrected before acceptance

#### Scenario: backend_reason is optional and informational

- **WHEN** a playbook declares `backend: safari` together with `backend_reason: "Apple Keychain session and anti-detection requirement"`
- **THEN** the playbook is valid, and the `backend_reason` value is preserved as documentation without affecting skill loading, routing, or auto-surfacing behavior
