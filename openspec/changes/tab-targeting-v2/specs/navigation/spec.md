## MODIFIED Requirements

### Requirement: Open URL in current tab

The system SHALL open a given URL in Safari. The default behavior SHALL be focus-existing: if any Safari tab's URL exactly matches the requested URL, the command SHALL reveal that existing tab using the spatial interaction gradient defined in the `non-interference` spec (layer 1 no-op / layer 2 tab-switch / layer 3 window raise / layer 4 cross-Space new-tab). Otherwise, the command SHALL open the URL in a new tab within the front window of the current Space.

When the caller supplies `--replace-tab`, the command SHALL instead navigate the front window's current tab to the requested URL via `do JavaScript "window.location.href=..."`, ignoring any matching existing tab. When the caller supplies any of the targeting flags (`--url`, `--window`, `--tab`, `--document`, `--tab-in-window`), the command SHALL navigate the resolved target tab via `do JavaScript "window.location.href=..."` regardless of focus-existing considerations; the targeting flags explicitly select which tab to modify.

When no Safari window exists, the system SHALL create a new document regardless of any flag configuration.

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
- **AND** user runs `safari-browser open https://example.com` (or with any flag)
- **THEN** the system SHALL create a new Safari document at `https://example.com`
