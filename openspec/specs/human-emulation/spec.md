# human-emulation Specification

## Purpose

TBD - created by archiving change 'tab-targeting-v2'. Update Purpose after archive.

## Requirements

### Requirement: Principle declaration

safari-browser default behaviors SHALL emulate how a human uses Safari through its GUI. When a design decision must choose between an implementation-convenient behavior and a human-intuitive behavior, the default SHALL favor the human-intuitive behavior. Alternative behaviors MAY be exposed through explicit opt-in flags (e.g., `--replace-tab`, `--first-match`).

The `human-emulation` principle SHALL hold cross-cutting authority equivalent to the `non-interference` principle. When the two principles conflict for a given command, the command's specification SHALL resolve the conflict explicitly using the spatial gradient defined in this specification.

#### Scenario: Default command behavior follows human intuition

- **WHEN** a developer adds a new safari-browser subcommand that takes a URL or a tab reference
- **THEN** the default behavior SHALL match what a human would expect after performing the equivalent action through Safari's GUI
- **AND** any implementation-level deviation from that behavior SHALL be exposed through a named opt-in flag rather than altering the default

#### Scenario: Cross-principle conflict uses spatial gradient

- **WHEN** a command's design would force a conflict between human-emulation (e.g., focus an existing tab) and non-interference (e.g., avoid raising a window)
- **THEN** the command's specification SHALL apply the spatial gradient defined in requirement "Spatial interaction gradient" below rather than silently picking one principle


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Tab bar as ground truth

All target-resolution subcommands SHALL observe Safari's tab state through the same abstraction a human observes through the Safari window chrome: every tab in every window is individually addressable, and no tab is hidden from enumeration. The CLI SHALL NOT expose any abstraction where a background tab within a window is invisible to one subcommand while visible to another.

In practice, this means target resolution SHALL be implemented against the `tabs of windows` AppleScript collection (which enumerates every tab), not against the `documents` collection (which exposes only the front tab of each window).

#### Scenario: documents subcommand sees all tabs

- **WHEN** Safari has one window containing two tabs (`https://a.example/` at index 1, `https://b.example/` at index 2, with `b` being the current tab)
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain two lines, one per tab, including the background tab `https://a.example/`
- **AND** the output SHALL NOT omit any tab that is reachable via the Safari GUI

#### Scenario: Cross-subcommand tab enumeration is consistent

- **WHEN** Safari has N tabs total across all windows
- **AND** user queries the same tab state via `safari-browser documents` and via any targeted subcommand's resolver error listing (e.g., the `availableDocuments` field of `documentNotFound`)
- **THEN** both enumerations SHALL list the same N tabs
- **AND** no tab SHALL be present in one listing and absent in the other


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Fail-closed on user-visible ambiguity

When a target selector resolves to more than one Safari tab in a way that a human would also find ambiguous (e.g., two tabs with URLs both containing the same substring), the command SHALL fail-closed with a `ambiguousWindowMatch` error that lists all matching tabs, rather than silently choosing one.

Silent first-match behavior MAY be exposed as an opt-in through a `--first-match` flag. When `--first-match` is used, the command SHALL still emit a stderr warning enumerating all matches and indicating which one was selected, so that debugging remains possible.

#### Scenario: Ambiguous URL substring fails closed

- **WHEN** Safari has two tabs whose URLs both contain the substring `plaud`
- **AND** user runs any targeted subcommand with `--url plaud`
- **THEN** the command SHALL exit with `ambiguousWindowMatch` listing both matching tabs with window and tab-in-window indices
- **AND** no AppleScript side effect SHALL be performed against either tab

#### Scenario: --first-match opt-in logs selection

- **WHEN** user runs `safari-browser js --url plaud --first-match "document.title"` and two tabs match `plaud`
- **THEN** the command SHALL select the first matching tab deterministically
- **AND** SHALL emit a stderr warning listing all matching tabs and indicating which was chosen


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Focus-existing for known URLs

When a command's purpose is to make a URL visible to the user (e.g., `open <url>`), and Safari already has a tab whose URL exactly matches the requested URL, the default behavior SHALL be to focus that existing tab rather than navigate the front tab or create a duplicate tab.

"Focus the existing tab" resolves to a specific action determined by the spatial interaction gradient defined below. The original "navigate front tab" behavior MAY be preserved through an explicit `--replace-tab` opt-in.

#### Scenario: Open URL that is already open

- **WHEN** Safari has a tab at `https://web.plaud.ai/` (not currently focused)
- **AND** user runs `safari-browser open https://web.plaud.ai/`
- **THEN** the system SHALL focus the existing tab rather than navigate the current tab or open a new duplicate tab
- **AND** focus resolution SHALL follow the spatial gradient (switch tab within window, or raise window in current Space, or open new tab in current Space if cross-Space)

#### Scenario: --replace-tab preserves legacy behavior

- **WHEN** user runs `safari-browser open --replace-tab https://web.plaud.ai/` with the same state as above
- **THEN** the system SHALL navigate the current tab of the front window to `https://web.plaud.ai/` regardless of whether an existing tab matches
- **AND** SHALL NOT raise or focus any other tab


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Spatial interaction gradient

When a command must reveal a target tab that is not currently focused, it SHALL choose the action based on the spatial relationship between the invocation context and the target tab. The gradient has four layers, applied in order:

1. **Target is front tab of front window** — no action; the tab is already visible.
2. **Target is a background tab within the same window** — issue AppleScript `set current tab of window N to tab T` to switch tab within the window. This action is classified as passively interfering and transitively authorized under the command's existing semantics (no new opt-in flag required).
3. **Target is in a different window within the same macOS Space** — activate that window (raise to front) and, if necessary, switch its current tab. This action is classified as passively interfering; an `stderr` warning SHALL be emitted.
4. **Target is in a window on a different macOS Space** — do NOT perform cross-Space raise. Instead, fall back to opening a new tab in the current Space's front window (or the inferred user-active window).

Space membership SHALL be detected via CGWindow API (`kCGWindowWorkspace` or equivalent). If the required permissions are not granted, the system SHALL fallback to the same-Space behavior (layer 3) rather than introduce unauthorized interference, and SHALL emit a stderr note indicating Space detection was unavailable.

#### Scenario: Same-window background tab switches without warning

- **WHEN** Safari's front window has two tabs and the target is the background tab
- **AND** the command's semantics permit tab switching (e.g., `open --focus-existing`)
- **THEN** the system SHALL switch the current tab of that window to the target tab
- **AND** SHALL NOT emit any stderr interference warning

#### Scenario: Cross-window same-Space raise emits warning

- **WHEN** the target tab is in window 2 and window 1 is currently frontmost, and both windows are in the same Space
- **THEN** the system SHALL activate window 2 (raising it to front)
- **AND** SHALL switch window 2's current tab to the target tab if needed
- **AND** SHALL emit a stderr warning indicating the window was raised

#### Scenario: Cross-Space target falls back to new tab

- **WHEN** the target tab exists in window 3 which is on a different macOS Space from the caller's current Space
- **AND** Space detection succeeds via CGWindow API
- **THEN** the system SHALL NOT raise window 3 or switch Space
- **AND** SHALL open a new tab in the current Space's front window navigated to the requested URL
- **AND** SHALL emit a stderr note indicating the existing tab was left on another Space

#### Scenario: Space detection unavailable falls back to same-Space behavior

- **WHEN** CGWindow API denies access (screen recording permission not granted)
- **AND** a focus-existing operation needs cross-Space classification
- **THEN** the system SHALL treat the target as same-Space (performing layer 3 raise) rather than guess
- **AND** SHALL emit a stderr note indicating Space detection was unavailable

<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->
