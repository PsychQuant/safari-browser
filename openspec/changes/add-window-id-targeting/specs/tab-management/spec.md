## MODIFIED Requirements

### Requirement: Switch to tab by index

The system SHALL switch the target Safari window's current tab to the tab at the given index. The default target SHALL be the front window. When `--window <n>` is provided, the system SHALL operate on window `n`. When `--window-id <id>` is provided, the system SHALL operate on `window id <id>`, after checking that the window exists (and belongs to `--profile`, when given), and SHALL fail with a document-not-found error otherwise. With `--profile` and no window flag, the system SHALL operate on the profile's window by the id the enumeration read. Flags that name a tab (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) SHALL be rejected because the tab-switch operation changes UI state inside a window.

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

#### Scenario: Switch to tab in a window by id

- **WHEN** user runs `safari-browser tab 3 --window-id 4711`
- **THEN** the current tab of window 4711 becomes its tab 3, addressed as `window id 4711`
- **AND** no other window is changed

### Requirement: Open new empty tab

The system SHALL open a new empty tab in the target Safari window. The default target SHALL be the front window; `--window <n>` overrides it, and its id SHALL be read before Safari is activated. `--window-id <id>` SHALL create the tab in `window id <id>` without activating Safari, after checking that the window exists (and belongs to `--profile`, when given); the new tab SHALL still become that window's current tab. With `--profile` and no window flag, the tab SHALL be created in the profile's window by the id the enumeration read. Flags that name a tab SHALL be rejected for this operation.

#### Scenario: New tab in front window

- **WHEN** user runs `safari-browser tab new`
- **THEN** a new tab is created in the front window and becomes the current tab

#### Scenario: New tab in specific window

- **WHEN** user runs `safari-browser tab --window 2 new`
- **THEN** a new tab is created in window 2 and becomes its current tab

#### Scenario: New tab in a window by id

- **WHEN** user runs `safari-browser tab new --window-id 4711`
- **THEN** a new tab is created in window 4711 and becomes its current tab
- **AND** Safari is not activated
