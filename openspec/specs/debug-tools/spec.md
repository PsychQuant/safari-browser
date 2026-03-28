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

---
### Requirement: Multi-level console capture

The system SHALL capture all console methods (log, warn, error, info, debug) when `--start` is invoked. Each captured message SHALL include a level prefix.

#### Scenario: Capture warn and error

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.warn('low disk')` and `console.error('failed')`
- **THEN** `safari-browser console` output includes `[warn] low disk` and `[error] failed`

#### Scenario: Capture debug and info

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.info('loaded')` and `console.debug('v=2')`
- **THEN** `safari-browser console` output includes `[info] loaded` and `[debug] v=2`

#### Scenario: Log level has no prefix for backwards compatibility

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.log('hello')`
- **THEN** `safari-browser console` output includes `hello` (no `[log]` prefix, preserving existing behavior)

<!-- @trace
source: parity-with-agent-browser
updated: 2026-03-28
code:
  - Sources/SafariBrowser/Commands/TabsCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - README.md
  - Tests/Fixtures/test-page.html
  - Makefile
  - Sources/SafariBrowser/Commands/DragCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Tests/e2e-test.sh
  - LICENSE
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
-->