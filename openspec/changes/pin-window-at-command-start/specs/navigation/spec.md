## MODIFIED Requirements

### Requirement: Open URL in current tab

The system SHALL open a given URL in Safari. The default behavior SHALL be focus-existing: if any Safari tab's URL exactly matches the requested URL, the command SHALL reveal that existing tab using the spatial interaction gradient defined in the `non-interference` spec (layer 1 no-op / layer 2 tab-switch / layer 3 window raise / layer 4 cross-Space new-tab). Otherwise, the command SHALL open the URL in a new tab within the front window of the current Space.

When the caller supplies `--replace-tab`, the command SHALL instead navigate the front window's current tab to the requested URL via `do JavaScript "window.location.href=..."`, ignoring any matching existing tab. When the caller supplies any of the targeting flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--window-id`, `--tab`, `--document`, `--tab-in-window`) or `--profile`, the command SHALL navigate the resolved target tab via `do JavaScript "window.location.href=..."` regardless of focus-existing considerations; the targeting flags explicitly select which tab to modify.

When no Safari window exists, the system SHALL create a new document with no target flag, with `--replace-tab`, and with `--window <n>`. With any other target flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window-id`, `--tab`, `--document`, `--window <n> --tab-in-window <m>`) or `--profile`, the command SHALL fail with a document-not-found error and no window SHALL be created. A target named by `--window-id`, resolved to a window id through `--profile`, or `--window <n>` (with or without `--tab-in-window <m>`) resolved to its window id at command start, SHALL be read before navigating, and Safari SHALL be activated only after navigating. `--window <n>` resolves to an id only when window `n` exists when the command starts (see document-targeting, "Window number resolved to its id at command start"); when no Safari window exists then, it keeps its position and the system SHALL create a new document as above. A window that existed at command start and closed before the navigation SHALL make the command fail with a document-not-found error, and no window SHALL be created.

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

#### Scenario: Window number is read by id before navigating

- **WHEN** user runs `safari-browser open --window 2 https://example.com/b`
- **AND** window 2 exists when the command starts and has id 4711
- **THEN** the system reads `window id 4711` before navigating, navigates the current tab of that window, and activates Safari only after navigating
- **AND** no AppleScript sent after the id was read names `window 2`

#### Scenario: Window number whose window closes before the navigation

- **WHEN** user runs `safari-browser open --window 2 https://example.com/b`
- **AND** the window that was window 2 at command start closes before the navigation
- **THEN** the command fails with a document-not-found error naming window 2 and its window id
- **AND** no tab of the window now in position 2 is navigated and no window is created
