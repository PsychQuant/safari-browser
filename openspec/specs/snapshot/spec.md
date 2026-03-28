# snapshot Specification

## Purpose

TBD - created by archiving change 'snapshot-refs'. Update Purpose after archive.

## Requirements

### Requirement: Scan interactive elements and assign refs

The system SHALL scan the current page's DOM for interactive elements and assign sequential ref IDs (`@e1`, `@e2`, ...). The element references SHALL be stored in `window.__sbRefs` as an array. The output SHALL list each element with its ref ID, tag, type, and descriptive text.

#### Scenario: Snapshot a login form

- **WHEN** user runs `safari-browser snapshot` on a page with an email input, password input, and submit button
- **THEN** stdout contains lines like:
  ```
  @e1  input[type="email"]  placeholder="Email"
  @e2  input[type="password"]  placeholder="Password"
  @e3  button  "Sign In"
  ```
  and `window.__sbRefs` contains the 3 DOM elements

#### Scenario: Snapshot empty page

- **WHEN** user runs `safari-browser snapshot` on a page with no interactive elements
- **THEN** stdout is empty and `window.__sbRefs` is an empty array


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Interactive-only filter

The system SHALL scan only interactive elements by default: `input`, `button`, `a`, `select`, `textarea`, `[role="button"]`, `[role="link"]`, `[role="menuitem"]`, `[role="tab"]`, `[contenteditable]`, and elements with `onclick` attribute.

#### Scenario: Non-interactive elements excluded

- **WHEN** user runs `safari-browser snapshot` on a page with divs, spans, and paragraphs alongside a button
- **THEN** only the button appears in the output


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Scope snapshot to selector

The system SHALL support `--selector` (`-s`) option to limit scanning to descendants of the first element matching the given CSS selector.

#### Scenario: Scoped snapshot

- **WHEN** user runs `safari-browser snapshot -s "form.login"`
- **THEN** only interactive elements within `form.login` are listed


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Re-snapshot replaces refs

The system SHALL clear and replace `window.__sbRefs` on each snapshot invocation. Previous refs become invalid.

#### Scenario: Re-snapshot after navigation

- **WHEN** user runs `safari-browser snapshot`, then navigates to another page, then runs `safari-browser snapshot` again
- **THEN** the new snapshot replaces all previous refs

<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Compact snapshot mode

The system SHALL support `--compact` (`-c`) flag that excludes hidden elements (display:none, visibility:hidden, zero dimensions) from the snapshot output.

#### Scenario: Compact snapshot

- **WHEN** user runs `safari-browser snapshot -c` on a page with hidden inputs and visible buttons
- **THEN** only visible interactive elements appear in the output


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

---
### Requirement: Depth-limited snapshot

The system SHALL support `--depth` (`-d`) option that limits scanning to elements within N levels of DOM depth from the scope root.

#### Scenario: Depth 3 snapshot

- **WHEN** user runs `safari-browser snapshot -d 3`
- **THEN** only interactive elements within 3 levels of nesting from body are listed


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

---
### Requirement: Improved element descriptions

The snapshot output SHALL include element id (if present), first 3 CSS classes (if present), and disabled state.

#### Scenario: Element with id and classes

- **WHEN** an input has `id="email"` and `class="form-input lg primary"`
- **THEN** the snapshot line shows `@eN  input[type="email"]  #email .form-input.lg.primary  placeholder="Email"`

#### Scenario: Disabled element

- **WHEN** a button has the `disabled` attribute
- **THEN** the snapshot line includes `[disabled]`

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