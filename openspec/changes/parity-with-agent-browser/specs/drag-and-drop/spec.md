## ADDED Requirements

### Requirement: Drag element to target

The system SHALL simulate drag and drop by dispatching dragstart on the source element, dragover and drop on the target element, and dragend on the source element.

#### Scenario: Drag from source to destination

- **WHEN** user runs `safari-browser drag ".item" ".dropzone"`
- **THEN** dragstart is dispatched on `.item`, dragover and drop on `.dropzone`, and dragend on `.item`

#### Scenario: Source element not found

- **WHEN** user runs `safari-browser drag ".missing" ".dropzone"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .missing"

#### Scenario: Target element not found

- **WHEN** user runs `safari-browser drag ".item" ".missing"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .missing"
