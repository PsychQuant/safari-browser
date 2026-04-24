# document-listing Specification

## Purpose

TBD - created by archiving change 'multi-document-targeting'. Update Purpose after archive.

## Requirements

### Requirement: List all Safari documents

The system SHALL provide a `documents` subcommand that prints every Safari tab across every window in `(window, tab-in-window)` enumeration order. The output SHALL be deterministic so that the tab coordinates shown in this command match the coordinates accepted by `--window <M> --tab-in-window <N>` on other subcommands. The output SHALL NOT hide background tabs within a window; every tab reachable via the Safari GUI SHALL appear.

The subcommand's default text output SHALL include at minimum: a global 1-indexed document counter, the window index, the tab-in-window index, the URL, and the tab title. Machine-readable output via `--json` SHALL include the same fields as named properties.

This requirement supersedes any earlier behavior in which `documents` only enumerated one document per window (i.e., iterated Safari's `documents` collection). The canonical enumeration source SHALL be `tabs of windows`, consistent with the `human-emulation` principle that tab bar is ground truth.

#### Scenario: List documents shows every tab across windows

- **WHEN** Safari has two windows — window 1 with two tabs (`https://a.example/`, `https://b.example/`) and window 2 with one tab (`https://c.example/`)
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain three lines corresponding to the three tabs in enumeration order
- **AND** each line SHALL include the window index and the tab-in-window index
- **AND** passing `--window 1 --tab-in-window 2` to any subsequent subcommand SHALL target the `https://b.example/` tab

#### Scenario: List documents on single-window single-tab Safari

- **WHEN** Safari has one window with one tab at `https://example.com/`
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain a single line identifying the tab with window index `1` and tab-in-window index `1`

#### Scenario: List documents exposes background tabs

- **WHEN** Safari has one window with three tabs (`a`, `b`, `c`) where `b` is the current tab and `a`/`c` are background
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL include all three tabs
- **AND** SHALL NOT omit the background tabs `a` and `c`

#### Scenario: Current tab indicator in output

- **WHEN** Safari has three tabs as in the previous scenario and user runs `safari-browser documents`
- **THEN** the output SHALL indicate which tab within each window is the current tab (e.g., via an asterisk, a column, or a JSON `is_current: true` field)
- **AND** the indicator SHALL be stable across invocations while tab state is unchanged

#### Scenario: Cross-command tab enumeration consistency

- **WHEN** `safari-browser documents` reports N tabs
- **AND** user then runs `safari-browser upload --native ... --url <substring>` with a pattern that should match K of those tabs
- **THEN** the upload command's ambiguity error (when K > 1) SHALL list exactly those K tabs
- **AND** SHALL NOT list any tab absent from the `documents` output nor omit any tab that `documents` showed as matching


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Machine-readable JSON output

The system SHALL support a `--json` flag on the `documents` subcommand that emits the same information as a JSON array. Each element SHALL be an object with at least the keys `index`, `url`, and `title`.

#### Scenario: Documents JSON output

- **WHEN** user runs `safari-browser documents --json`
- **THEN** stdout SHALL be a valid JSON array
- **AND** each element SHALL contain an integer `index`, a string `url`, and a string `title`


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Empty Safari state

The system SHALL handle the case where Safari is running but has no documents open. In text mode the output SHALL be empty (no lines). In JSON mode the output SHALL be an empty array `[]`. The system SHALL NOT throw `noSafariWindow` when Safari is running but document-less.

#### Scenario: Running Safari with no documents

- **WHEN** Safari is running but has closed every window
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL be empty or contain only a trailing newline
- **AND** the command SHALL exit with status 0

#### Scenario: Empty JSON output

- **WHEN** Safari is running but has no documents
- **AND** user runs `safari-browser documents --json`
- **THEN** stdout SHALL be exactly `[]` (optionally with a trailing newline)


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Discovery aid for documentNotFound errors

The output format of the `documents` subcommand SHALL match the `availableDocuments` listing embedded in `SafariBrowserError.documentNotFound` error descriptions, so users experiencing a not-found error can run `safari-browser documents` and see consistent formatting.

#### Scenario: Error listing matches documents output

- **WHEN** a `documentNotFound` error is raised with `availableDocuments` listing two URLs
- **AND** the user immediately runs `safari-browser documents`
- **THEN** both outputs SHALL refer to the same documents in the same index order

<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->
