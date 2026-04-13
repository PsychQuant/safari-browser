## MODIFIED Requirements

### Requirement: Open URL in current tab

The system SHALL open a given URL in Safari. The default target SHALL be the front window's current tab. If the caller supplies any of the global targeting flags (`--url`, `--window`, `--tab`, `--document`), the system SHALL open the URL in the resolved target document instead, using `do JavaScript "window.location.href=..."` against that document reference.

When no Safari window exists, the system SHALL create a new document regardless of target flags.

#### Scenario: Open URL with no target

- **WHEN** user runs `safari-browser open https://example.com`
- **THEN** the system navigates the current tab of the front window to `https://example.com`

#### Scenario: Open URL in specific document by URL pattern

- **WHEN** Safari has two documents and user runs `safari-browser open --url plaud https://plaud.ai/upload`
- **THEN** the system navigates only the document whose URL already contains `plaud` to `https://plaud.ai/upload`
- **AND** the other document SHALL remain unchanged

#### Scenario: Open URL in specific window

- **WHEN** user runs `safari-browser open --window 2 https://example.com`
- **THEN** the system navigates the current tab of window 2 to `https://example.com`
- **AND** window 1 SHALL remain unchanged

#### Scenario: Target not found during open

- **WHEN** user runs `safari-browser open --url missing https://example.com`
- **AND** no document URL contains the substring `missing`
- **THEN** the system SHALL throw `documentNotFound` listing all available document URLs
- **AND** no navigation SHALL occur

---
### Requirement: Open URL in new tab

The system SHALL open a given URL in a new tab of the target window. When no target flag is provided, the system SHALL use the front window. When `--window <n>` is provided, the system SHALL open the new tab in window `n`. Other targeting flags (`--url`, `--tab`, `--document`) SHALL be rejected for `open --new-tab` because "new tab" operates on a window, not on a document.

#### Scenario: New tab in front window

- **WHEN** user runs `safari-browser open https://example.com --new-tab`
- **THEN** the system opens a new tab in the front window at `https://example.com`

#### Scenario: New tab in specific window

- **WHEN** user runs `safari-browser open --window 2 https://example.com --new-tab`
- **THEN** the system opens a new tab in window 2
- **AND** window 1 SHALL remain unchanged

#### Scenario: New tab rejects document-level targeting

- **WHEN** user runs `safari-browser open --url plaud https://example.com --new-tab`
- **THEN** the system SHALL reject the invocation with a validation error explaining that `--new-tab` only accepts `--window`
