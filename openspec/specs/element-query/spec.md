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

---
### Requirement: Element query commands honor document targeting

All element-query commands (`find`, `get html`, `get value`, `get attr`, `get count`, `get box`) SHALL execute their underlying JavaScript against the target document resolved from the global targeting flags. The default target SHALL be `document 1`. Global targeting flags (`--url`, `--window`, `--tab`, `--document`) SHALL redirect the query to the resolved document.

All element-query commands SHALL use document-scoped AppleScript references so modal file dialog sheets on the front window do NOT block read-only queries.

#### Scenario: Get HTML from specific document

- **WHEN** Safari has two documents and user runs `safari-browser get html --url plaud ".main"`
- **THEN** stdout contains the innerHTML of `.main` inside the document whose URL contains `plaud`

#### Scenario: Get count honors window targeting

- **WHEN** user runs `safari-browser get count --window 2 "a"`
- **THEN** stdout contains the count of `<a>` elements inside the document of window 2

#### Scenario: Get value honors document index

- **WHEN** user runs `safari-browser get value --document 3 "input#email"`
- **THEN** stdout contains the value of `input#email` inside document 3

#### Scenario: Get box honors targeting

- **WHEN** user runs `safari-browser get box --url plaud ".upload-button"`
- **THEN** stdout contains the bounding box JSON of `.upload-button` inside the matched document
- **AND** the coordinates SHALL be relative to that document's viewport

#### Scenario: Query while front window has modal sheet

- **WHEN** Safari's front window shows an open modal file dialog sheet
- **AND** user runs `safari-browser get count "button"`
- **THEN** the command returns the count within the default process timeout
- **AND** SHALL NOT hang waiting for the modal

#### Scenario: Element not found is scoped to target document

- **WHEN** Safari has two documents — only one contains `.missing`
- **AND** user runs `safari-browser get html --url plaud ".missing"`
- **AND** the `plaud` document does not contain `.missing`
- **THEN** the CLI SHALL exit with non-zero status and stderr SHALL contain `Element not found: .missing`
- **AND** SHALL NOT report the content from the other document

<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->
