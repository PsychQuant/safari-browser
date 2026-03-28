# pdf-export Specification

## Purpose

TBD - created by archiving change 'parity-with-agent-browser'. Update Purpose after archive.

## Requirements

### Requirement: Export page as PDF

The system SHALL export the current Safari page as PDF using System Events to trigger File > Export as PDF, saving to the specified path.

#### Scenario: Export to PDF

- **WHEN** user runs `safari-browser pdf /tmp/page.pdf`
- **THEN** the current page is exported as PDF to `/tmp/page.pdf`

#### Scenario: Default path

- **WHEN** user runs `safari-browser pdf` without a path argument
- **THEN** the page is exported as PDF to `page.pdf` in the current directory

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