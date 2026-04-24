# tab-management Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: List all tabs

The system SHALL list the open tabs of the target Safari window, printing each tab's index, title, and URL to stdout. The default target SHALL be the front window. When `--window <n>` is provided, the system SHALL list the tabs of window `n` instead. Other targeting flags (`--url`, `--tab`, `--document`) SHALL be rejected because "listing tabs" only makes sense at window granularity.

#### Scenario: List tabs of front window

- **WHEN** user runs `safari-browser tabs` with no target flag
- **THEN** stdout contains a list of tabs of the front window with format `<index>\t<title>\t<url>` per line

#### Scenario: List tabs of specific window

- **WHEN** user runs `safari-browser tabs --window 2`
- **AND** window 2 has three tabs
- **THEN** stdout contains exactly three lines, listing the tabs of window 2
- **AND** SHALL NOT include any tabs from window 1

#### Scenario: No tabs open

- **WHEN** user runs `safari-browser tabs` and Safari has no windows
- **THEN** stdout is empty and the CLI exits with zero status

#### Scenario: tabs rejects document-level targeting

- **WHEN** user runs `safari-browser tabs --url plaud`
- **THEN** the system SHALL reject the invocation with a validation error explaining that `tabs` only accepts `--window`


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Switch to tab by index

The system SHALL switch the target Safari window's current tab to the tab at the given index. The default target SHALL be the front window. When `--window <n>` is provided, the system SHALL operate on window `n`. Document-level targeting flags (`--url`, `--tab`, `--document`) SHALL be rejected because the tab-switch operation changes UI state inside a window.

#### Scenario: Switch to valid tab in front window

- **WHEN** user runs `safari-browser tab 2`
- **THEN** Safari's front window switches to the tab at index 2

#### Scenario: Switch to tab in specific window

- **WHEN** user runs `safari-browser tab --window 2 3`
- **THEN** window 2's current tab becomes the tab at index 3
- **AND** window 1's current tab SHALL remain unchanged

#### Scenario: Invalid tab index

- **WHEN** user runs `safari-browser tab 99` and the target window has fewer than 99 tabs
- **THEN** the CLI exits with non-zero status and stderr contains an error message


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Open new empty tab

The system SHALL open a new empty tab in the target Safari window. The default target SHALL be the front window; `--window <n>` overrides it. Document-level targeting flags SHALL be rejected for this operation.

#### Scenario: New tab in front window

- **WHEN** user runs `safari-browser tab new`
- **THEN** a new tab is created in the front window and becomes the current tab

#### Scenario: New tab in specific window

- **WHEN** user runs `safari-browser tab --window 2 new`
- **THEN** a new tab is created in window 2 and becomes its current tab

<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->
