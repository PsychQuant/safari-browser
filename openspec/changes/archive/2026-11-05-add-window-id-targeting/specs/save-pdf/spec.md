## MODIFIED Requirements

### Requirement: The target tab must be named explicitly

`save-pdf` SHALL require a tab-targeting flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` or `--window-id`, each with optional `--tab-in-window`, `--document`, or `--tab`). Without one it SHALL fail with a usage error before contacting Safari. `--first-match` alone is not a target. It SHALL accept `--profile`. The target SHALL be resolved once at the start. From the moment the page script runs, every step SHALL be tied to that document by its slot, which exists only there: when the tab shows another document afterwards, the command SHALL fail and SHALL NOT read it. Before that moment a position names whatever is at that position and a pattern whatever matches it, as for every command, and the output names the address read. When the tab vanishes, the error SHALL name the target and SHALL NOT list other tabs.

#### Scenario: no target

- **WHEN** the user runs `safari-browser save-pdf out.pdf`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: first-match alone is not a target

- **WHEN** the user runs `safari-browser save-pdf out.pdf --first-match`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: the tab vanishes during the read

- **WHEN** the targeted tab is closed after the command resolved it
- **THEN** the command exits 1 with an error naming the target, and the error lists no other tab
