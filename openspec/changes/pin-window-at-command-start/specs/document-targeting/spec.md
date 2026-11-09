## ADDED Requirements

### Requirement: Window number resolved to its id at command start

The commands in the closed list below SHALL resolve `--window <n>`, and `--window <n> --tab-in-window <m>`, to the stable id of the window that is the `n`-th window when the command starts, once, before any other Apple event of the command, and SHALL then target that window exactly as `--window-id <id>` targets it (see "Target a window by its stable id"): without `--tab-in-window`, the current tab of that window at each Apple event; with `--tab-in-window <m>`, its `m`-th tab. No AppleScript sent after the id was read SHALL name the window by its position. `--window <n>` keeps its meaning: `n` counts windows from the front, and with `--profile <name>` it counts only that profile's windows, at the moment the command starts.

Without `--profile`, the id SHALL be read with one query that names window `n` (with `--tab-in-window <m>`, the same query SHALL also read the window's tab count, and the id SHALL be used only when `1 <= m <= tab count`). With `--profile`, the id SHALL be the one the profile-scoped enumeration reads for that window. When the id cannot be read — no `n`-th window, a window with no tab, a tab `m` outside the window, an enumeration record without a window id, or any failure of the query or enumeration — the command SHALL keep the positional target, so that its first step fails, or runs, exactly as it did before this requirement. A cancelled command SHALL stop instead.

When the window whose id was read closes before a later step, that step SHALL fail with a document-not-found error and SHALL NOT act on the window now in position `n`, on the front window, or on any other window. The error's pattern SHALL name what the user typed and the id, `window <n> (window id <id> at command start)` (with `--tab-in-window`, `window <n> tab <m> (window id <id> at command start)`; with `--profile`, followed by `(profile: "<name>")`). Without `--profile` it SHALL list no other window's tabs. When `--profile` and `--tab-in-window` are both given to a command that resolves the profile once into a concrete tab, the pattern names the window id and tab only, as before this requirement.

The commands are a closed list: `back`, `check`, `uncheck`, `click`, `console`, `cookies get`, `cookies set`, `cookies clear`, `dblclick`, `drag`, `errors`, `fill`, `find`, `focus`, `forward`, every `get` subcommand, `highlight`, `hover`, every `is` subcommand, every `mouse` subcommand, `open` when it navigates (not `--new-tab` or `--new-window`), `pdf-cache get`, `press`, `reload`, `save-image`, `scroll`, `scrollintoview`, `select`, `set media`, `snapshot`, every `storage` subcommand, `tab is-marked`, `tab unmark`, `type`, `upload` on its JavaScript path (`--js`, or the default without Accessibility), and `exec`. `js`, `wait` and `save-pdf` already resolve `--window <n>` once at command start and additionally require the current tab not to change; `tabs`, `tab <n>`, `tab new`, `tab focus` and `open --new-tab` name the window by id themselves; `close`, `screenshot`, `pdf`, and `upload` on its native paths are out of scope (safari-browser#353); `documents` and `wait <ms>` read no tab. A command added later that composes the shared targeting options SHALL resolve `--window <n>` this way or be listed as an exception.

`click --mark-tab` (and `--mark-tab-persist`) SHALL resolve the id before it reads and rewrites the title, so the wrap, the click and the unwrap address the same window by id.

The id read at command start is not carried to the next command: a second command started with `--window <n>` reads the `n`-th window again.

#### Scenario: A window raised mid-command does not redirect later steps

- **WHEN** user runs `safari-browser click --mark-tab --window 2 "#go"`
- **AND** window 2 has id 4711 when the command starts
- **AND** another window is raised to position 2 after the first Apple event
- **THEN** the title is read and wrapped, the element is clicked, and the title is unwrapped in `window id 4711`
- **AND** no AppleScript sent after the id was read names `window 2`

#### Scenario: A window closed mid-command fails closed

- **WHEN** user runs `safari-browser get text --window 2 "#log"`
- **AND** window 2 has id 4711 when the command starts and closes before the text is read
- **THEN** the command fails with a document-not-found error whose pattern is `window 2 (window id 4711 at command start)`
- **AND** no text is read from the window now in position 2 or from the front window

#### Scenario: A tab of a window number

- **WHEN** user runs `safari-browser get url --window 1 --tab-in-window 3`
- **AND** window 1 has id 4711 and five tabs when the command starts
- **THEN** every reference after the id was read is `tab 3 of window id 4711`

#### Scenario: The id cannot be read at command start

- **WHEN** user runs `safari-browser get url --window 5` and Safari has two windows
- **THEN** the command keeps `--window 5` as a position and fails with the document-not-found error that lists the open windows, as it did before this requirement

#### Scenario: A tab outside the window at command start

- **WHEN** user runs `safari-browser get url --window 1 --tab-in-window 9` and window 1 has three tabs
- **THEN** the command keeps the positional target and fails with the document-not-found error it reported before this requirement

#### Scenario: Window number within a profile

- **WHEN** user runs `safari-browser get url --window 1 --profile Work`
- **AND** the first window of the profile `Work` is Safari's window 3, whose id is 4711
- **THEN** the id 4711 is read from one profile-scoped enumeration at command start
- **AND** the URL is read from the current tab of `window id 4711`, which is checked to belong to `Work` as for `--window-id 4711 --profile Work`

#### Scenario: Other targeting flags are not resolved

- **WHEN** user runs a listed command with `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--document`, `--tab`, `--window-id`, `--profile` alone, or no targeting flag
- **THEN** no AppleScript is sent to resolve a window id before the command's own steps
