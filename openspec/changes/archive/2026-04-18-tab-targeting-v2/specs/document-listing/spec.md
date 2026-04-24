## MODIFIED Requirements

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
