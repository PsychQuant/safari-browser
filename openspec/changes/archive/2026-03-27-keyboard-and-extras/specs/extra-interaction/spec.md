## ADDED Requirements

### Requirement: Focus element by selector

The system SHALL call `.focus()` on the first element matching the given CSS selector.

#### Scenario: Focus an input

- **WHEN** user runs `safari-browser focus "input#email"`
- **THEN** the input element receives focus

#### Scenario: Element not found

- **WHEN** user runs `safari-browser focus ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .nonexistent"

### Requirement: Check checkbox

The system SHALL set a checkbox element's `checked` property to `true` and dispatch a `change` event. If already checked, it SHALL be a no-op.

#### Scenario: Check an unchecked checkbox

- **WHEN** user runs `safari-browser check "input#agree"` and the checkbox is unchecked
- **THEN** the checkbox becomes checked and a `change` event is dispatched

#### Scenario: Check an already checked checkbox

- **WHEN** user runs `safari-browser check "input#agree"` and the checkbox is already checked
- **THEN** the checkbox remains checked (no-op)

#### Scenario: Element not found

- **WHEN** user runs `safari-browser check ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .nonexistent"

### Requirement: Uncheck checkbox

The system SHALL set a checkbox element's `checked` property to `false` and dispatch a `change` event. If already unchecked, it SHALL be a no-op.

#### Scenario: Uncheck a checked checkbox

- **WHEN** user runs `safari-browser uncheck "input#agree"` and the checkbox is checked
- **THEN** the checkbox becomes unchecked and a `change` event is dispatched

### Requirement: Double-click element by selector

The system SHALL dispatch a `dblclick` event on the first element matching the given CSS selector.

#### Scenario: Double-click an element

- **WHEN** user runs `safari-browser dblclick "td.cell"`
- **THEN** a `dblclick` event is dispatched on the element

#### Scenario: Element not found

- **WHEN** user runs `safari-browser dblclick ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .nonexistent"
