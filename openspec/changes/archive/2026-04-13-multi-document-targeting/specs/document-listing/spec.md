## ADDED Requirements

### Requirement: List all Safari documents

The system SHALL provide a `documents` subcommand that prints every Safari document's index, URL, and title in document-collection order. The output SHALL be deterministic so that the indices shown in this command match the indices accepted by `--document <n>`.

#### Scenario: List documents in text mode

- **WHEN** Safari has documents `[https://web.plaud.ai/ (Plaud Web), https://platform.claude.com/ (Claude Platform)]`
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain two lines, each with the document index, URL, and title
- **AND** the index of the first line SHALL be `1`
- **AND** passing that index as `--document 1` to any subsequent subcommand SHALL target the same document

#### Scenario: List documents when Safari has a single window

- **WHEN** Safari has one window with one tab open at `https://example.com/`
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain a single line identifying document 1 with URL `https://example.com/`

---
### Requirement: Machine-readable JSON output

The system SHALL support a `--json` flag on the `documents` subcommand that emits the same information as a JSON array. Each element SHALL be an object with at least the keys `index`, `url`, and `title`.

#### Scenario: Documents JSON output

- **WHEN** user runs `safari-browser documents --json`
- **THEN** stdout SHALL be a valid JSON array
- **AND** each element SHALL contain an integer `index`, a string `url`, and a string `title`

---
### Requirement: Empty Safari state

The system SHALL handle the case where Safari is running but has no documents open. In text mode the output SHALL be empty (no lines). In JSON mode the output SHALL be an empty array `[]`. The system SHALL NOT throw `noSafariWindow` when Safari is running but document-less.

#### Scenario: Running Safari with no documents

- **WHEN** Safari is running but has closed every window
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL be empty or contain only a trailing newline
- **AND** the command SHALL exit with status 0

#### Scenario: Empty JSON output

- **WHEN** Safari is running but has no documents
- **AND** user runs `safari-browser documents --json`
- **THEN** stdout SHALL be exactly `[]` (optionally with a trailing newline)

---
### Requirement: Discovery aid for documentNotFound errors

The output format of the `documents` subcommand SHALL match the `availableDocuments` listing embedded in `SafariBrowserError.documentNotFound` error descriptions, so users experiencing a not-found error can run `safari-browser documents` and see consistent formatting.

#### Scenario: Error listing matches documents output

- **WHEN** a `documentNotFound` error is raised with `availableDocuments` listing two URLs
- **AND** the user immediately runs `safari-browser documents`
- **THEN** both outputs SHALL refer to the same documents in the same index order
