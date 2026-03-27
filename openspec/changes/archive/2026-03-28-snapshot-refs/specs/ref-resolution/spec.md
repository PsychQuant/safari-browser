## ADDED Requirements

### Requirement: Resolve @ref in selector arguments

All commands that accept a CSS selector argument SHALL detect the `@eN` pattern (where N is a positive integer) and resolve it to the corresponding element from `window.__sbRefs[N-1]`. If the pattern does not start with `@`, it SHALL be treated as a CSS selector (existing behavior).

#### Scenario: Click by ref

- **WHEN** user runs `safari-browser snapshot` then `safari-browser click @e3`
- **THEN** the third element from the snapshot is clicked

#### Scenario: Fill by ref

- **WHEN** user runs `safari-browser snapshot` then `safari-browser fill @e1 "text"`
- **THEN** the first element from the snapshot is filled

#### Scenario: CSS selector still works

- **WHEN** user runs `safari-browser click "button.submit"` (no @ prefix)
- **THEN** the element is found via CSS selector (existing behavior unchanged)

### Requirement: Invalid ref error

The system SHALL exit with non-zero status when a @ref refers to an index that does not exist in `window.__sbRefs`.

#### Scenario: Ref out of range

- **WHEN** user runs `safari-browser click @e99` and there are fewer than 99 refs
- **THEN** the CLI exits with non-zero status and stderr contains "Invalid ref: @e99"

### Requirement: Stale ref error

The system SHALL exit with non-zero status when `window.__sbRefs` is not defined (no snapshot taken).

#### Scenario: No snapshot taken

- **WHEN** user runs `safari-browser click @e1` without running snapshot first
- **THEN** the CLI exits with non-zero status and stderr contains "No snapshot taken"
