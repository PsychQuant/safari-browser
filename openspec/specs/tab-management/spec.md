# tab-management Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: List all tabs

The system SHALL list all open tabs across all Safari windows, printing each tab's index, title, and URL to stdout.

#### Scenario: List tabs

- **WHEN** user runs `safari-browser tabs`
- **THEN** stdout contains a list of all tabs with format `<index>\t<title>\t<url>` per line

#### Scenario: No tabs open

- **WHEN** user runs `safari-browser tabs` and Safari has no windows
- **THEN** stdout is empty and the CLI exits with zero status

---
### Requirement: Switch to tab by index

The system SHALL switch Safari's current tab to the tab at the given index.

#### Scenario: Switch to valid tab

- **WHEN** user runs `safari-browser tab 2`
- **THEN** Safari's front window switches to tab at index 2

#### Scenario: Invalid tab index

- **WHEN** user runs `safari-browser tab 99` and there are fewer than 99 tabs
- **THEN** the CLI exits with non-zero status and stderr contains an error message

---
### Requirement: Open new empty tab

The system SHALL open a new empty tab in Safari's front window.

#### Scenario: New tab

- **WHEN** user runs `safari-browser tab new`
- **THEN** a new tab is created and becomes the current tab
