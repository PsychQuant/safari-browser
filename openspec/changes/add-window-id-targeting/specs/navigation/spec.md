## MODIFIED Requirements

### Requirement: Open URL in new tab

The system SHALL open a given URL in a new tab of the target window. When no target flag is provided, the system SHALL use the front window. When `--window <n>` is provided, the system SHALL read the id of window `n` before activating Safari and SHALL create the tab in the window with that id, so that activating Safari cannot redirect the tab to another window. When `--window-id <id>` is provided, the system SHALL create the tab in the window with that id without activating Safari, and the new tab SHALL become that window's current tab. When `--profile <name>` is provided, the system SHALL create the tab in the window resolved within that profile using the window id from the same enumeration, and SHALL fail rather than use the front window when the resolution cannot name one window. A window that no longer exists SHALL make the command fail without opening a tab elsewhere. Other targeting flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) SHALL be rejected for `open --new-tab` because "new tab" operates on a window, not on a document.

#### Scenario: New tab in front window

- **WHEN** user runs `safari-browser open https://example.com --new-tab`
- **THEN** the system opens a new tab in the front window at `https://example.com`

#### Scenario: New tab in specific window

- **WHEN** user runs `safari-browser open --window 2 https://example.com --new-tab`
- **THEN** the system reads the id of window 2 before activating Safari
- **AND** opens the new tab in the window with that id
- **AND** window 1 SHALL remain unchanged

#### Scenario: New tab in a window named by id

- **WHEN** user runs `safari-browser open --window-id 4711 https://example.com --new-tab`
- **THEN** the system opens the new tab in the window whose id is 4711
- **AND** Safari is not activated
- **AND** the new tab becomes the current tab of window 4711

#### Scenario: New tab in a profile's window

- **WHEN** user runs `safari-browser open --profile Work https://example.com --new-tab`
- **AND** two Safari windows are open, one of profile `Work` and one of another profile
- **THEN** the system opens the new tab in the `Work` window, named by the id read while resolving the profile

#### Scenario: New tab in a window that no longer exists

- **WHEN** user runs `safari-browser open --window-id 9999 https://example.com --new-tab`
- **AND** no Safari window has the id 9999
- **THEN** the command fails and no tab is opened in any window

#### Scenario: New tab rejects document-level targeting

- **WHEN** user runs `safari-browser open --url plaud https://example.com --new-tab`
- **THEN** the system SHALL reject the invocation with a validation error explaining that `--new-tab` only accepts `--window`, `--window-id` or `--profile`

## ADDED Requirements

### Requirement: Open with a window id names a target

`open` without `--new-tab` SHALL treat `--window-id` as an explicit target: it SHALL navigate the targeted tab and SHALL NOT search for an existing tab with the same URL or open a new tab in the front window.

#### Scenario: Navigate the current tab of a window by id

- **WHEN** user runs `safari-browser open --window-id 4711 https://example.com/b`
- **THEN** the current tab of window 4711 navigates to `https://example.com/b`
- **AND** no new tab is opened in any window
