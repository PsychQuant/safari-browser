## MODIFIED Requirements

### Requirement: Machine-readable JSON output

The system SHALL support a `--json` flag on the `documents` subcommand that emits the same information as a JSON array. Each element SHALL be an object with at least the keys `index`, `url`, `title` and `window_id`. `window_id` SHALL be the AppleScript id of the window that holds the document (the value accepted by `--window-id`), the same value as `blocking_dialog.window_id`, and SHALL be `null` when Safari does not report it.

#### Scenario: Documents JSON output

- **WHEN** user runs `safari-browser documents --json`
- **THEN** stdout SHALL be a valid JSON array
- **AND** each element SHALL contain an integer `index`, a string `url`, and a string `title`

#### Scenario: Window id at the top level

- **WHEN** user runs `safari-browser documents --json`
- **AND** a document is in the window whose id is 4711
- **THEN** that element contains `"window_id": 4711`
- **AND** the same element's `blocking_dialog.window_id` is 4711
