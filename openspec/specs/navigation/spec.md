# navigation Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

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


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

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


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

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
