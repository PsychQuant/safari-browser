# media-settings Specification

## Purpose

TBD - created by archiving change 'parity-with-agent-browser'. Update Purpose after archive.

## Requirements

### Requirement: Set color scheme preference

The system SHALL override the CSS `prefers-color-scheme` media query by injecting a style element that forces dark or light mode on the page.

#### Scenario: Set dark mode

- **WHEN** user runs `safari-browser set media dark`
- **THEN** the page renders as if `prefers-color-scheme: dark` is active

#### Scenario: Set light mode

- **WHEN** user runs `safari-browser set media light`
- **THEN** the page renders as if `prefers-color-scheme: light` is active

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