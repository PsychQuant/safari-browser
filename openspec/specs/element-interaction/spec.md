# element-interaction Specification

## Purpose

TBD - created by archiving change 'convenience-commands'. Update Purpose after archive.

## Requirements

### Requirement: Click element by selector

The system SHALL click the first element matching the given CSS selector via JavaScript `querySelector(selector).click()`.

#### Scenario: Click a button

- **WHEN** user runs `safari-browser click "button.submit"`
- **THEN** the first element matching `button.submit` is clicked

#### Scenario: Element not found

- **WHEN** user runs `safari-browser click ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .nonexistent"

---
### Requirement: Fill input by selector

The system SHALL clear the target input's value and set it to the given text, then dispatch `input` and `change` events.

#### Scenario: Fill a text input

- **WHEN** user runs `safari-browser fill "input#email" "user@example.com"`
- **THEN** the input's value becomes `user@example.com` and `input` + `change` events are fired

#### Scenario: Fill element not found

- **WHEN** user runs `safari-browser fill ".missing" "text"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .missing"

---
### Requirement: Type into element by selector

The system SHALL append text to the target element's current value, then dispatch an `input` event. Unlike `fill`, it SHALL NOT clear existing content.

#### Scenario: Type appends to existing value

- **WHEN** the input already contains "hello" and user runs `safari-browser type "input#name" " world"`
- **THEN** the input's value becomes `hello world`

---
### Requirement: Select dropdown option

The system SHALL set a `<select>` element's value to the given option value and dispatch a `change` event.

#### Scenario: Select an option

- **WHEN** user runs `safari-browser select "select#country" "TW"`
- **THEN** the select element's value becomes `TW` and a `change` event is fired

#### Scenario: Select element not found

- **WHEN** user runs `safari-browser select ".missing" "val"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found: .missing"

---
### Requirement: Hover element by selector

The system SHALL dispatch `mouseover` and `mouseenter` events on the first element matching the given CSS selector.

#### Scenario: Hover triggers tooltip

- **WHEN** user runs `safari-browser hover ".tooltip-trigger"`
- **THEN** `mouseover` and `mouseenter` events are dispatched on the element

---
### Requirement: Scroll page by direction

The system SHALL scroll the page in the given direction by the specified pixel amount (default 500px).

#### Scenario: Scroll down default

- **WHEN** user runs `safari-browser scroll down`
- **THEN** the page scrolls down by 500 pixels

#### Scenario: Scroll with custom pixels

- **WHEN** user runs `safari-browser scroll up 200`
- **THEN** the page scrolls up by 200 pixels

#### Scenario: Scroll directions

- **WHEN** user runs `safari-browser scroll left` or `safari-browser scroll right`
- **THEN** the page scrolls horizontally by 500 pixels in the given direction
