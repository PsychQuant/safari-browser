# keyboard Specification

## Purpose

TBD - created by archiving change 'keyboard-and-extras'. Update Purpose after archive.

## Requirements

### Requirement: Press a keyboard key

The system SHALL dispatch keydown and keyup events on the currently focused element (or document.body if nothing is focused) for the given key name.

#### Scenario: Press Enter to submit form

- **WHEN** user runs `safari-browser press Enter` and an input element is focused
- **THEN** keydown and keyup events with `key: "Enter"` are dispatched on the focused element

#### Scenario: Press Escape

- **WHEN** user runs `safari-browser press Escape`
- **THEN** keydown and keyup events with `key: "Escape"` are dispatched

#### Scenario: Press Tab

- **WHEN** user runs `safari-browser press Tab`
- **THEN** keydown and keyup events with `key: "Tab"` are dispatched

#### Scenario: Press arrow keys

- **WHEN** user runs `safari-browser press ArrowDown`
- **THEN** keydown and keyup events with `key: "ArrowDown"` are dispatched

---
### Requirement: Press key with modifiers

The system SHALL support modifier key combinations in the format `Modifier+Key` (e.g., `Control+a`, `Shift+Tab`). Supported modifiers: Control, Shift, Alt, Meta.

#### Scenario: Select all with Control+a

- **WHEN** user runs `safari-browser press Control+a`
- **THEN** keydown and keyup events are dispatched with `key: "a"`, `ctrlKey: true`

#### Scenario: Shift+Tab for reverse focus

- **WHEN** user runs `safari-browser press Shift+Tab`
- **THEN** keydown and keyup events are dispatched with `key: "Tab"`, `shiftKey: true`
