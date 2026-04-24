# drag-and-drop Specification

## Purpose

TBD - created by archiving change 'parity-with-agent-browser'. Update Purpose after archive.

## Requirements

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
