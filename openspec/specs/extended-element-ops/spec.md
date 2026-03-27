# extended-element-ops Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Scroll element into view

The system SHALL scroll the first element matching the CSS selector into the visible area using `scrollIntoView({behavior: 'smooth', block: 'center'})`.

#### Scenario: Scroll element into view

- **WHEN** user runs `safari-browser scrollintoview "footer"`
- **THEN** the footer element is scrolled into the visible viewport

#### Scenario: Element not found

- **WHEN** user runs `safari-browser scrollintoview ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"

---
### Requirement: Get element bounding box

The system SHALL print the bounding box (x, y, width, height) of the first element matching the CSS selector as JSON.

#### Scenario: Get bounding box

- **WHEN** user runs `safari-browser get box "h1"`
- **THEN** stdout contains JSON like `{"x":8,"y":10,"width":500,"height":38}`

#### Scenario: Element not found

- **WHEN** user runs `safari-browser get box ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"

---
### Requirement: Check if element is enabled

The system SHALL check if the element's `disabled` property is false, printing "true" or "false".

#### Scenario: Enabled element

- **WHEN** user runs `safari-browser is enabled "button.submit"` and the button is not disabled
- **THEN** stdout contains `true`

#### Scenario: Disabled element

- **WHEN** user runs `safari-browser is enabled "button.submit"` and the button has `disabled` attribute
- **THEN** stdout contains `false`

---
### Requirement: Check if checkbox is checked

The system SHALL check the `checked` property of a checkbox element, printing "true" or "false".

#### Scenario: Checked checkbox

- **WHEN** user runs `safari-browser is checked "input#agree"` and it is checked
- **THEN** stdout contains `true`

#### Scenario: Unchecked checkbox

- **WHEN** user runs `safari-browser is checked "input#agree"` and it is not checked
- **THEN** stdout contains `false`
