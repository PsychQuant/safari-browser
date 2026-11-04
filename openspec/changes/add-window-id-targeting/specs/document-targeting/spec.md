## ADDED Requirements

### Requirement: Target a window by its stable id

The system SHALL accept a global `--window-id <id>` flag on every subcommand that composes the shared targeting options. The value SHALL be a positive integer naming a Safari window by its AppleScript `id of window`, which does not change while the window exists. Without `--tab-in-window`, the target SHALL be the current tab of that window, read once at command start. With `--tab-in-window <m>`, the target SHALL be the `m`-th tab of that window, referenced as `tab m of window id <id>`.

`--window-id` SHALL be mutually exclusive with `--window`, `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab` and `--document`; a combination SHALL be rejected with a validation error before Safari is contacted. `--tab-in-window` SHALL be accepted with either `--window` or `--window-id`. When `--profile <name>` is also given, the window SHALL belong to that profile; otherwise the command SHALL fail without acting. When no window has the given id, the command SHALL fail with a document-not-found error and SHALL NOT fall back to the front window or to any other window. A value below 1 SHALL be rejected with a validation error.

#### Scenario: Current tab of a window by id

- **WHEN** user runs `safari-browser get url --window-id 4711`
- **AND** Safari has a window whose id is 4711 and whose current tab shows `https://example.com/a`
- **THEN** the command prints `https://example.com/a`

#### Scenario: A tab of a window by id

- **WHEN** user runs `safari-browser js --window-id 4711 --tab-in-window 2 "document.title"`
- **THEN** the script runs in `tab 2 of window id 4711`
- **AND** a change of window order between resolution and execution does not redirect it

#### Scenario: Window id that does not exist

- **WHEN** user runs `safari-browser get url --window-id 9999`
- **AND** no Safari window has the id 9999
- **THEN** the command fails with a document-not-found error
- **AND** no other window is read

#### Scenario: Window id outside the requested profile

- **WHEN** user runs `safari-browser get url --window-id 4711 --profile Work`
- **AND** window 4711 belongs to the profile `Personal`
- **THEN** the command fails without reading the window

#### Scenario: Window id combined with another targeting flag

- **WHEN** user runs `safari-browser get url --window-id 4711 --window 1`
- **THEN** the system rejects the invocation with a validation error naming both flags

#### Scenario: Window id below one

- **WHEN** user runs `safari-browser get url --window-id 0`
- **THEN** the system rejects the invocation with a validation error

#### Scenario: Window id in an exec script

- **WHEN** user runs `safari-browser exec --window-id 4711` with a script whose steps read the page
- **THEN** every step targets the current tab of window 4711 in the in-process path and in the subprocess path alike
