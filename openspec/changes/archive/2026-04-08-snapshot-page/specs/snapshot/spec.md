## ADDED Requirements

### Requirement: Page flag for full page state

The `snapshot` command SHALL accept a `--page` flag. When provided, the command SHALL execute the full page state scan (as defined in the `snapshot-page` spec) instead of the default interactive-only scan. All existing flags (`-c`, `-s`, `-d`, `--json`) SHALL remain functional and combinable with `--page`.

#### Scenario: Snapshot with --page flag

- **WHEN** user runs `safari-browser snapshot --page`
- **THEN** the output is a full page state scan (accessibility tree + metadata) instead of the default interactive element list

#### Scenario: Snapshot without --page flag unchanged

- **WHEN** user runs `safari-browser snapshot` (no `--page`)
- **THEN** the output is the existing interactive element list with `@ref` IDs, identical to current behavior
