## MODIFIED Requirements

### Requirement: Open URL in new tab

The system SHALL open a given URL in a new tab of the target window. When no target flag is provided, the system SHALL use the front window. When `--window <n>` is provided, the system SHALL read the id of window `n` before activating Safari and SHALL create the tab in the window with that id, so that activating Safari cannot redirect the tab to another window. When `--window-id <id>` is provided, the system SHALL create the tab in the window with that id without activating Safari, and the new tab SHALL become that window's current tab. When `--profile <name>` is provided, the system SHALL create the tab in the window resolved within that profile using the window id from the same enumeration, and SHALL fail rather than use the front window when the resolution cannot name one window. A window named by `--window-id` or resolved to an id that no longer exists SHALL make the command fail without opening a tab elsewhere. With no Safari window open, `--window <n>` makes a new document, as `open` does without a flag. When the enumeration reports no window id for the profile's window (legacy records), the system SHALL use that window's position, read before activating Safari as for `--window <n>`. Other targeting flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) SHALL be rejected for `open --new-tab` because "new tab" operates on a window, not on a document.

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

### Requirement: Open URL in current tab

The system SHALL open a given URL in Safari. The default behavior SHALL be focus-existing: if any Safari tab's URL exactly matches the requested URL, the command SHALL reveal that existing tab using the spatial interaction gradient defined in the `non-interference` spec (layer 1 no-op / layer 2 tab-switch / layer 3 window raise / layer 4 cross-Space new-tab). Otherwise, the command SHALL open the URL in a new tab within the front window of the current Space.

When the caller supplies `--replace-tab`, the command SHALL instead navigate the front window's current tab to the requested URL via `do JavaScript "window.location.href=..."`, ignoring any matching existing tab. When the caller supplies any of the targeting flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--window-id`, `--tab`, `--document`, `--tab-in-window`) or `--profile`, the command SHALL navigate the resolved target tab via `do JavaScript "window.location.href=..."` regardless of focus-existing considerations; the targeting flags explicitly select which tab to modify.

When no Safari window exists, the system SHALL create a new document with no target flag, with `--replace-tab`, and with `--window <n>`. With any other target flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window-id`, `--tab`, `--document`, `--window <n> --tab-in-window <m>`) or `--profile`, the command SHALL fail with a document-not-found error and no window SHALL be created. A target named by `--window-id`, or resolved to a window id through `--profile`, SHALL be read before navigating, and Safari SHALL be activated only after navigating.

When `--url <substring>` is used with `open` and more than one tab matches, the command SHALL fail-closed with `ambiguousWindowMatch` unless `--first-match` is supplied (per the unified fail-closed policy in `document-targeting`).

This requirement supersedes the earlier default of "navigate the front window's current tab" when no targeting flag was supplied; that behavior is now opt-in via `--replace-tab`.

#### Scenario: Open URL that is already open focuses existing tab

- **WHEN** Safari has a tab at `https://web.plaud.ai/` in window 2 (background window) and user runs `safari-browser open https://web.plaud.ai/`
- **THEN** the system SHALL apply the spatial gradient: same-Space cross-window → raise window 2, switch to the matching tab, emit stderr warning
- **AND** SHALL NOT navigate the current tab of window 1 or create a duplicate tab

#### Scenario: Open URL that is not open creates new tab

- **WHEN** Safari has tabs but none matches `https://new.example/` and user runs `safari-browser open https://new.example/`
- **THEN** the system SHALL open a new tab navigated to `https://new.example/` in the front window of the current Space
- **AND** the existing tabs SHALL NOT be modified

#### Scenario: --replace-tab preserves legacy behavior

- **WHEN** Safari has an existing tab at `https://web.plaud.ai/` (background) and user runs `safari-browser open --replace-tab https://web.plaud.ai/`
- **THEN** the system SHALL navigate the current tab of the front window to `https://web.plaud.ai/` via `do JavaScript window.location.href=...`
- **AND** SHALL NOT raise or focus the existing background tab

#### Scenario: Open URL in specific document by URL pattern

- **WHEN** Safari has two documents and user runs `safari-browser open --url plaud https://plaud.ai/upload`
- **AND** exactly one tab's URL contains the substring `plaud`
- **THEN** the system SHALL navigate that tab to `https://plaud.ai/upload` via `do JavaScript window.location.href=...`
- **AND** the other tab SHALL remain unchanged

#### Scenario: Open URL with --url matching multiple tabs fails closed

- **WHEN** Safari has two tabs both matching `--url plaud` and user runs `safari-browser open --url plaud https://plaud.ai/new` without `--first-match`
- **THEN** the command SHALL exit with `ambiguousWindowMatch` listing both matching tabs
- **AND** SHALL NOT navigate either tab

#### Scenario: Open URL in specific window

- **WHEN** user runs `safari-browser open --window 2 https://example.com`
- **THEN** the system SHALL navigate the current tab of window 2 to `https://example.com`
- **AND** window 1 SHALL remain unchanged

#### Scenario: Open URL in specific tab-in-window

- **WHEN** window 1 has three tabs and user runs `safari-browser open --window 1 --tab-in-window 3 https://example.com`
- **THEN** the system SHALL navigate tab 3 of window 1 to `https://example.com`
- **AND** the other tabs of window 1 SHALL remain unchanged

#### Scenario: Target not found during open

- **WHEN** user runs `safari-browser open --url missing https://example.com`
- **AND** no tab URL contains the substring `missing`
- **THEN** the system SHALL exit with `documentNotFound` listing all available tabs
- **AND** no navigation SHALL occur

#### Scenario: No Safari window exists

- **WHEN** Safari is running but has zero windows
- **AND** user runs `safari-browser open https://example.com` (or with `--replace-tab` or `--window <n>`)
- **THEN** the system SHALL create a new Safari document at `https://example.com`

#### Scenario: A URL flag other than --url navigates the matching tab

- **WHEN** user runs `safari-browser open https://new.example/ --url-endswith "/report"` and exactly one tab's URL ends with `/report`
- **THEN** the system navigates that tab to `https://new.example/`
- **AND** no new tab is opened

#### Scenario: A URL flag that matches nothing fails

- **WHEN** user runs `safari-browser open https://new.example/ --url-exact https://nope.example/` and no tab has that URL
- **THEN** the command fails with a document-not-found error
- **AND** no tab is navigated and no tab or window is created

#### Scenario: Window id with no Safari window open

- **WHEN** user runs `safari-browser open https://new.example/ --window-id 4711` and Safari has no window
- **THEN** the command fails with a document-not-found error and no window is created

## ADDED Requirements

### Requirement: Open with a window id names a target

`open` without `--new-tab` SHALL treat `--window-id` as an explicit target: it SHALL navigate the targeted tab and SHALL NOT search for an existing tab with the same URL or open a new tab in the front window.

#### Scenario: Navigate the current tab of a window by id

- **WHEN** user runs `safari-browser open --window-id 4711 https://example.com/b`
- **THEN** the current tab of window 4711 navigates to `https://example.com/b`
- **AND** no new tab is opened in any window
