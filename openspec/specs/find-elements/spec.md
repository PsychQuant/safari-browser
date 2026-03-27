# find-elements Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Find element by text content

The system SHALL find the first element whose textContent contains the given value and perform the specified action (click, fill, etc.).

#### Scenario: Find and click by text

- **WHEN** user runs `safari-browser find text "Submit" click`
- **THEN** the first element containing "Submit" in its textContent is clicked

#### Scenario: Find and fill by placeholder

- **WHEN** user runs `safari-browser find placeholder "Email" fill "user@example.com"`
- **THEN** the first input with placeholder "Email" is filled with the given text

---
### Requirement: Find element by ARIA role

The system SHALL find the first element with the given ARIA role attribute and perform the specified action.

#### Scenario: Find button by role

- **WHEN** user runs `safari-browser find role "button" click`
- **THEN** the first element with `role="button"` is clicked

---
### Requirement: Find element by label

The system SHALL find the first input associated with a label containing the given text and perform the specified action.

#### Scenario: Find input by label

- **WHEN** user runs `safari-browser find label "Password" fill "secret"`
- **THEN** the input associated with the label containing "Password" is filled

---
### Requirement: Element not found handling

The system SHALL exit with non-zero status when no element matches the find criteria.

#### Scenario: No match found

- **WHEN** user runs `safari-browser find text "NonexistentText" click`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"
