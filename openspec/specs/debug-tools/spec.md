# debug-tools Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Capture console output

The system SHALL inject a console.log override that buffers messages, then retrieve and print them on demand.

#### Scenario: Start capturing and retrieve

- **WHEN** user runs `safari-browser console --start` to begin capturing, then later runs `safari-browser console`
- **THEN** stdout contains all console.log messages captured since start

#### Scenario: Clear console buffer

- **WHEN** user runs `safari-browser console --clear`
- **THEN** the captured console buffer is emptied

---
### Requirement: Capture JS errors

The system SHALL inject a window.onerror handler that buffers errors, then retrieve and print them on demand.

#### Scenario: Retrieve captured errors

- **WHEN** user runs `safari-browser errors`
- **THEN** stdout contains all JS errors captured since the handler was installed

#### Scenario: Clear error buffer

- **WHEN** user runs `safari-browser errors --clear`
- **THEN** the captured error buffer is emptied

---
### Requirement: Highlight element

The system SHALL add a visible red outline to the first element matching the CSS selector for debugging purposes.

#### Scenario: Highlight an element

- **WHEN** user runs `safari-browser highlight "button.submit"`
- **THEN** the element gets a `2px solid red` outline style

#### Scenario: Element not found

- **WHEN** user runs `safari-browser highlight ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"

---
### Requirement: Mouse move

The system SHALL dispatch a mousemove event at the given x,y coordinates on the document.

#### Scenario: Move mouse to coordinates

- **WHEN** user runs `safari-browser mouse move 100 200`
- **THEN** a mousemove event is dispatched at clientX=100, clientY=200

---
### Requirement: Mouse down and up

The system SHALL dispatch mousedown or mouseup events on the element at the current mouse position (or document).

#### Scenario: Mouse down

- **WHEN** user runs `safari-browser mouse down`
- **THEN** a mousedown event is dispatched

#### Scenario: Mouse up

- **WHEN** user runs `safari-browser mouse up`
- **THEN** a mouseup event is dispatched

---
### Requirement: Mouse wheel

The system SHALL dispatch a wheel event with the given deltaY value.

#### Scenario: Scroll with wheel

- **WHEN** user runs `safari-browser mouse wheel 300`
- **THEN** a wheel event with deltaY=300 is dispatched on the document
