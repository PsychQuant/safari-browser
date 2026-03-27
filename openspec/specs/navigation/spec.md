# navigation Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: Open URL in current tab

The system SHALL open a given URL in Safari's current tab by default.

#### Scenario: Open URL replaces current tab

- **WHEN** user runs `safari-browser open https://example.com`
- **THEN** the current tab's URL changes to `https://example.com`

#### Scenario: Safari is not running

- **WHEN** user runs `safari-browser open https://example.com` and Safari is not running
- **THEN** Safari launches and opens the URL in a new window

---
### Requirement: Open URL in new tab

The system SHALL open a URL in a new tab when `--new-tab` flag is provided.

#### Scenario: New tab flag

- **WHEN** user runs `safari-browser open https://example.com --new-tab`
- **THEN** a new tab is created with the given URL

---
### Requirement: Open URL in new window

The system SHALL open a URL in a new window when `--new-window` flag is provided.

#### Scenario: New window flag

- **WHEN** user runs `safari-browser open https://example.com --new-window`
- **THEN** a new Safari window is created with the given URL

---
### Requirement: Navigate back

The system SHALL navigate the current tab to the previous page via JavaScript `history.back()`.

#### Scenario: Back navigation

- **WHEN** user runs `safari-browser back`
- **THEN** the current tab navigates to the previous page in history

---
### Requirement: Navigate forward

The system SHALL navigate the current tab to the next page via JavaScript `history.forward()`.

#### Scenario: Forward navigation

- **WHEN** user runs `safari-browser forward`
- **THEN** the current tab navigates to the next page in history

---
### Requirement: Reload page

The system SHALL reload the current tab via JavaScript `location.reload()`.

#### Scenario: Reload current page

- **WHEN** user runs `safari-browser reload`
- **THEN** the current tab reloads its content

---
### Requirement: Close current tab

The system SHALL close the current tab in Safari.

#### Scenario: Close tab

- **WHEN** user runs `safari-browser close`
- **THEN** the current tab is closed via AppleScript `close current tab`
