# unit-tests Specification

## Purpose

TBD - created by archiving change 'test-infrastructure'. Update Purpose after archive.

## Requirements

### Requirement: Test string escaping for AppleScript

The system SHALL verify that `escapedForAppleScript` correctly escapes backslashes and double quotes.

#### Scenario: Escape double quotes

- **WHEN** the string `He said "hello"` is escaped for AppleScript
- **THEN** the result is `He said \"hello\"`

#### Scenario: Escape backslashes

- **WHEN** the string `path\to\file` is escaped for AppleScript
- **THEN** the result is `path\\to\\file`


<!-- @trace
source: test-infrastructure
updated: 2026-03-28
code:
  - README.md
  - Tests/Fixtures/test-page.html
  - Tests/e2e-test.sh
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Makefile
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
-->

---
### Requirement: Test string escaping for JavaScript

The system SHALL verify that `escapedForJS` correctly escapes backslashes and single quotes.

#### Scenario: Escape single quotes

- **WHEN** the string `it's` is escaped for JS
- **THEN** the result is `it\'s`


<!-- @trace
source: test-infrastructure
updated: 2026-03-28
code:
  - README.md
  - Tests/Fixtures/test-page.html
  - Tests/e2e-test.sh
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Makefile
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
-->

---
### Requirement: Test ref resolution JS generation

The system SHALL verify that `resolveRefJS` generates correct JS for both @ref and CSS selector inputs.

#### Scenario: CSS selector passthrough

- **WHEN** `resolveRefJS` is called on `"button.submit"`
- **THEN** the result contains `document.querySelector('button.submit')`

#### Scenario: Ref resolution

- **WHEN** `resolveRefJS` is called on `"@e3"`
- **THEN** the result contains `window.__sbRefs[2]`

#### Scenario: isRef detection

- **WHEN** `isRef` is checked on `"@e1"` and `"button"`
- **THEN** `@e1` returns true and `button` returns false


<!-- @trace
source: test-infrastructure
updated: 2026-03-28
code:
  - README.md
  - Tests/Fixtures/test-page.html
  - Tests/e2e-test.sh
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Makefile
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
-->

---
### Requirement: Test error descriptions

The system SHALL verify that each `SafariBrowserError` case produces the correct error message.

#### Scenario: Element not found error

- **WHEN** `SafariBrowserError.elementNotFound("button.missing")` is created
- **THEN** `errorDescription` is `"Element not found: button.missing"`

#### Scenario: Timeout error

- **WHEN** `SafariBrowserError.timeout(seconds: 30)` is created
- **THEN** `errorDescription` is `"Timeout after 30 seconds"`


<!-- @trace
source: test-infrastructure
updated: 2026-03-28
code:
  - README.md
  - Tests/Fixtures/test-page.html
  - Tests/e2e-test.sh
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Makefile
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
-->

---
### Requirement: Test command argument parsing

The system SHALL verify that ArgumentParser correctly parses command arguments without executing the command.

#### Scenario: Open command parses URL

- **WHEN** `OpenCommand` is parsed with arguments `["https://example.com"]`
- **THEN** the `url` property is `"https://example.com"` and `newTab` is false

#### Scenario: Open command parses flags

- **WHEN** `OpenCommand` is parsed with arguments `["https://example.com", "--new-tab"]`
- **THEN** `newTab` is true

#### Scenario: JS command validation

- **WHEN** `JSCommand` is parsed with no arguments and no --file
- **THEN** validation throws an error

#### Scenario: Wait command parses timeout

- **WHEN** `WaitCommand` is parsed with arguments `["--url", "dashboard", "--timeout", "5000"]`
- **THEN** `url` is `"dashboard"` and `timeout` is `5000`

<!-- @trace
source: test-infrastructure
updated: 2026-03-28
code:
  - README.md
  - Tests/Fixtures/test-page.html
  - Tests/e2e-test.sh
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Makefile
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
-->
