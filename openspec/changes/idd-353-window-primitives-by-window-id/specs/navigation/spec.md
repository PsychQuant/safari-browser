## MODIFIED Requirements

### Requirement: Close current tab

The system SHALL close one tab in Safari with `close`. With no targeting flag the tab SHALL be the current tab of the front window. With a flag that names a window and no tab (`--window`, `--window-id` or `--profile`, without `--tab-in-window`) it SHALL be the current tab of that window at the moment the close script runs. With a flag that names a tab (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) it SHALL be that tab, whether or not it is the current tab of its window.

`close` SHALL send one AppleScript that closes the tab, and that names the window and the tab as "Window-level commands act on the window they resolved" of document-targeting requires. `close` SHALL NOT make any tab current before it closes: when the tab it closes is a background tab, the current tab of that window is the same tab after the command as before it. In that same AppleScript, before anything is closed, the command SHALL fail when Safari has no window and when the target window has no tab.

#### Scenario: Close tab

- **WHEN** user runs `safari-browser close`
- **THEN** the current tab of the front window is closed

#### Scenario: Close a background tab found by its URL

- **WHEN** window id 5822 has the tabs `https://work.example/a1` (current) and `https://work.example/a2`
- **AND** user runs `safari-browser close --url work.example/a2`
- **THEN** one AppleScript closes `tab 2 of window id 5822`
- **AND** `https://work.example/a1` is still the current tab of that window
- **AND** no AppleScript of the command makes another tab current

#### Scenario: Close in a window that has no tab

- **WHEN** user runs `safari-browser close --window-id 5822` and window id 5822 has no tab
- **THEN** the command fails with an error that says the window has no tabs
- **AND** nothing is closed

##### Example: which tab close closes

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Tab closed | Current tab of that window afterwards |
| --- | --- | --- |
| `close` | tab 1 of window 1 | Safari's choice |
| `close --window 2` | tab 1 of window id 5822 | Safari's choice |
| `close --url work.example/a2` | tab 2 of window id 5822 | tab 1, unchanged |
| `close --window-id 4711 --tab-in-window 3` | tab 3 of window id 4711 | tab 1, unchanged |
| `close --document 5` | tab 2 of window id 5822 | tab 1, unchanged |
| `close --url work.example/a2`, when tab 2 of window id 5822 shows `https://other.example/` by the time the close script runs | none; target-changed error | tab 1, unchanged |
