## ADDED Requirements

### Requirement: JSON output for snapshot

The system SHALL output snapshot results as a JSON array when `--json` flag is provided. Each element SHALL include ref, tag, type, and descriptive attributes.

#### Scenario: Snapshot with --json

- **WHEN** user runs `safari-browser snapshot --json`
- **THEN** stdout contains a JSON array like `[{"ref":"@e1","tag":"input","type":"email","placeholder":"Email"}, ...]`

### Requirement: JSON output for tabs

The system SHALL output tab list as a JSON array when `--json` flag is provided.

#### Scenario: Tabs with --json

- **WHEN** user runs `safari-browser tabs --json`
- **THEN** stdout contains a JSON array like `[{"index":1,"title":"Example","url":"https://example.com"}, ...]`

### Requirement: JSON output for get box

The system SHALL output bounding box as JSON by default (already implemented). The `--json` flag SHALL be a no-op for `get box` since it already outputs JSON.

#### Scenario: Get box output

- **WHEN** user runs `safari-browser get box "h1"`
- **THEN** stdout contains JSON like `{"x":8,"y":10,"width":500,"height":38}`

### Requirement: JSON output for cookies get

The system SHALL output cookies as a JSON object when `--json` flag is provided.

#### Scenario: Cookies get with --json

- **WHEN** user runs `safari-browser cookies get --json`
- **THEN** stdout contains a JSON object like `{"session_id":"abc","theme":"dark"}`
