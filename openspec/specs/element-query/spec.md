# element-query Specification

## Purpose

TBD - created by archiving change 'convenience-commands'. Update Purpose after archive.

## Requirements

### Requirement: Check if element is visible

The system SHALL check if the first element matching the CSS selector is visible (has non-zero dimensions and is not hidden by CSS), printing "true" or "false" to stdout.

#### Scenario: Visible element

- **WHEN** user runs `safari-browser is visible "button.submit"` and the button is rendered and visible
- **THEN** stdout contains `true` and exit code is 0

#### Scenario: Hidden element

- **WHEN** user runs `safari-browser is visible ".hidden-div"` and the element has `display: none`
- **THEN** stdout contains `false` and exit code is 0

#### Scenario: Element does not exist

- **WHEN** user runs `safari-browser is visible ".nonexistent"`
- **THEN** stdout contains `false` and exit code is 0

---
### Requirement: Check if element exists

The system SHALL check if any element matches the given CSS selector, printing "true" or "false" to stdout.

#### Scenario: Element exists

- **WHEN** user runs `safari-browser is exists "input#email"` and the element is in the DOM
- **THEN** stdout contains `true`

#### Scenario: Element does not exist

- **WHEN** user runs `safari-browser is exists ".nonexistent"`
- **THEN** stdout contains `false`
