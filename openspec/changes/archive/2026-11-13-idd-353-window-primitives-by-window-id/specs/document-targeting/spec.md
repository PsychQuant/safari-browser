## ADDED Requirements

### Requirement: Window-level commands act on the window they resolved

`close`, `pdf`, `screenshot`, `upload` on its native paths (`--native`, `--allow-hid`, or the default when Accessibility is granted), and `open` when it reveals an existing tab SHALL, once their target is resolved, name the target window as `window id <id>` in every AppleScript they send afterwards, where `<id>` is the id the resolution read for that window. After the resolution no AppleScript of the command SHALL name the target window by its position (`window <n>`), and none SHALL reach the target window through Safari's `front window`, except inside a check that stops the command unless `id of front window` is `<id>`. An enumeration that lists every window does not name the target, and neither does the new tab `open` creates in the front window when it leaves a window on another Space alone. The steps a System Events block performs on the file sheet of the front window are outside this sentence; that check is what guards them (see file-upload and pdf-export).

Two cases keep the position, and the list is closed:

1. `close`, `pdf`, `screenshot` or `upload` was given no targeting flag and no `--profile`. The command acts on the front window with the scripts it sent before this requirement (safari-browser#287).
2. No id is available for the window: `--window <n>` stayed a position at command start (the note of "Window number resolved to its id at command start" was written), or the enumeration record of the resolved window carries no window id. The command sends the same scripts with `window <n>` in place of `window id <id>`.

When the resolution names one tab (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`, or the URL `open` was asked to reveal), the command SHALL name it `tab <t> of window id <id>`. `<t>` is a position inside that window (safari-browser#188).

When the tab was found by its URL (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, or the URL `open` was asked to reveal), the first AppleScript that acts on it (closes it, makes it the current tab, or raises its window) SHALL check the tab's URL before it acts, in that same AppleScript, and SHALL act only when the check holds. The check is case-sensitive. For `--url`, `--url-exact` and `--url-endswith` it holds when the URL still satisfies the flag. For `--url-regex` it holds when the URL equals the URL the resolution read for that tab, or, when that URL is longer than 2,000 characters, starts with its first 2,000 characters. For `open` it holds when the URL equals the requested URL. When the check fails the command SHALL fail with a target-changed error that says nothing was done to the tab, and SHALL NOT resolve the target again. A tab named by its position (`--tab`, `--document`, `--tab-in-window`) is not checked. `pdf` and the native `upload` paths run the check on every tab the resolution names, whether or not it was the current tab of its window when it was resolved.

When the target window is no longer open at a step that names it by its id, the command SHALL fail with a document-not-found error before that step acts: no tab is closed, no tab is made current, no window is raised, no keystroke or click is sent, and nothing is captured. The command SHALL NOT act on the window now in that position, on the front window, or on any other window. For a window whose id was read from `--window <n>` at command start, the error's pattern SHALL be the one "Window number resolved to its id at command start" defines.

The Examples below check the AppleScript text each command sends and the order it is sent in. What a keystroke, a raise or a capture does on a real Safari is outside their reach.

#### Scenario: A window raised after the resolution does not redirect the command

- **WHEN** user runs `safari-browser close --window 2`, window 2 has id 5822 when the command starts, and another window is raised to position 2 before the tab is closed
- **THEN** the current tab of `window id 5822` is closed
- **AND** no AppleScript sent after the id was read names `window 2`

#### Scenario: The target window closes before the command acts

- **WHEN** user runs `safari-browser close --window 2`, window 2 has id 5822 when the command starts, and that window closes before the tab is closed
- **THEN** the command fails with a document-not-found error whose pattern begins with `window 2 (window id 5822 at command start)`
- **AND** no tab of any other window is closed

#### Scenario: A tab found by its URL has moved

- **WHEN** user runs `safari-browser close --url work.example/a2`, the resolution finds it as tab 2 of window id 5822, and tab 2 of that window shows another URL when the close script runs
- **THEN** the command fails with a target-changed error
- **AND** no tab is closed

#### Scenario: No targeting flag

- **WHEN** user runs `safari-browser close` with no targeting flag and no `--profile`
- **THEN** the command sends the scripts it sent before this requirement, which name `window 1`

##### Example: references after the resolution

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Target at resolution | Window reference in every later AppleScript |
| --- | --- | --- |
| `close --window 2` | window 2 has id 5822 | `window id 5822` |
| `close --url work.example/a2` | tab 2 of window id 5822 | `tab 2 of window id 5822` |
| `close --window-id 5822 --tab-in-window 2` | window id 5822 | `tab 2 of window id 5822` |
| `pdf --allow-hid --window 2 out.pdf` | window 2 has id 5822 | `window id 5822` |
| `upload --native "input" f.txt --window 2` | window 2 has id 5822 | `window id 5822` |
| `screenshot --window 2 out.png` | window 2 has id 5822 | `window id 5822` |
| `open https://work.example/b1` | tab 1 of window id 6933 shows that URL | `window id 6933` |

##### Example: the URL check before acting

| Flag | URL the resolution read | URL of the tab when the script runs | Result |
| --- | --- | --- | --- |
| `--url work.example/a2` | `https://work.example/a2` | `https://work.example/a2?x=1` | acts |
| `--url work.example/a2` | `https://work.example/a2` | `https://work.example/A2` | target-changed error |
| `--url-exact https://work.example/a2` | `https://work.example/a2` | `https://work.example/a2#top` | target-changed error |
| `--url-endswith /a2` | `https://work.example/a2` | `https://other.example/a2` | acts |
| `--url-regex 'a[0-9]$'` | `https://work.example/a2` | `https://work.example/a2` | acts |
| `--url-regex 'a[0-9]$'` | `https://work.example/a2` | `https://work.example/a3` | target-changed error |
| `--url-regex` on a URL of 2,500 characters | that URL | a URL with the same first 2,000 characters | acts |
| `--tab-in-window 2` | (not read) | any URL | acts |

##### Example: cases that keep the position

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | State at command start | Window reference |
| --- | --- | --- |
| `close` | as above | `window 1`, scripts unchanged |
| `close --window 2` | the id of window 2 cannot be read | `window 2`, after the one note |
| `close --window 5` | as above | the one note, then the document-not-found error it gave before |
| `close --profile Work` | windows 2 and 3 belong to the profile `Work` | `window id 5822` |

## MODIFIED Requirements

### Requirement: Native path URL resolution to window index

The system SHALL resolve `TargetOptions` into a physical Safari window before dispatching any keystroke-based or window-scoped AppleScript operation. The resolver SHALL accept all four targeting flags (`--url`, `--window`, `--tab`, `--document`) for window-only primitives (`upload --native`, `upload --allow-hid`, `close`, `pdf`, `screenshot`) and map them to that window's index, to its stable id when one can be read, and, when the flag names a tab, to the position of that tab inside the window, using the following rules:

1. `--window N` (or no flag → front window): window N (or window 1 for the front window). For these primitives `--window N` reaches the resolver already resolved to the window's id by "Window number resolved to its id at command start", unless that id could not be read.
2. `--document N` / `--tab N`: map the Nth entry in Safari's document collection to the physical window that currently owns that document, and return that window's index.
3. `--url <pattern>`: enumerate all Safari documents in window order, select the window whose document URL contains `<pattern>` as a substring, and return that window's index, together with the URL read for the matching tab.

What these primitives do with the result is defined by "Window-level commands act on the window they resolved".

The resolver SHALL execute entirely within a single Swift process invocation (no shell subprocess chaining), and SHALL be stateless across resolver calls within the same process (no caching of prior results).

#### Scenario: Resolver accepts --url for native upload

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/` and one showing `https://github.com/`
- **AND** user runs `safari-browser upload --native "input[type=file]" "/tmp/audio.mp3" --url plaud`
- **THEN** the system SHALL resolve `--url plaud` to the window index of the plaud window
- **AND** SHALL dispatch the native file-dialog keystroke sequence to that resolved window
- **AND** SHALL NOT reject the invocation at validation time

#### Scenario: Resolver accepts --window for backward compatibility

- **WHEN** user runs `safari-browser upload --native "input[type=file]" "/tmp/file.mp3" --window 2`
- **AND** window 2 has id 5822 when the command starts
- **THEN** the system SHALL raise `window id 5822` and dispatch the keystroke path against it
- **AND** SHALL NOT reject the invocation at validation time

#### Scenario: Resolver accepts --document for native path

- **WHEN** Safari has three documents spread across two windows
- **AND** user runs `safari-browser screenshot --document 3 /tmp/shot.png`
- **THEN** the system SHALL identify which physical window owns the third document in Safari's document collection
- **AND** SHALL dispatch the screenshot capture against that window

##### Example: what the resolver returns

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Flag | Window index | Window id | Tab in the window | URL read for the tab |
| --- | --- | --- | --- | --- |
| `--url a2` | 2 | 5822 | 2 | `https://work.example/a2` |
| `--url-regex 'home.*/1$'` | 1 | 4711 | 1 | `https://home.example/1` |
| `--document 4` | 2 | 5822 | 1 | (none) |
| `--window-id 5822 --tab-in-window 2` | 2 | 5822 | 2 | (none) |
| `--window-id 5822` | 2 | 5822 | (none) | (none) |

### Requirement: Tab auto-switch before keystroke dispatch

When the resolution names a tab, `pdf` and the native `upload` paths SHALL bring it forward before dispatching any keystroke: one AppleScript names the window and the tab as "Window-level commands act on the window they resolved" requires, runs that requirement's URL check when the tab was found by its URL, and makes the tab the window's current tab when it is not (`set current tab of window id <id> to tab <t> of window id <id>`). A tab that is already current is checked and left as it is. `pdf` SHALL do this inside its export script. `upload` SHALL do it in one AppleScript before it opens the file dialog, and SHALL then read the page and click the file input in that tab only while it is still the window's current tab; when another tab has become current, the upload SHALL stop with a target-changed error before the file dialog opens. `close` and `screenshot` SHALL NOT switch tabs. The tab switch SHALL be classified as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag.

**Concurrent modification window** (#26 verify P1-3, safari-browser#353): the native-path workflow still spans several AppleScript runs: the resolver's enumeration, the tab switch of `upload`, its read that checks the target exists, and the script that sends the keystrokes. Safari's windows can change between them. Because every run after the resolution names the window by its id, a window that closed fails the command with a document-not-found error, and a window that moved in the window order is still the one acted on. A tab that closed or moved inside its window is caught only for a tab found by its URL; a tab named by its position is not.

#### Scenario: Target URL in background tab of a window

- **WHEN** Safari window 1 has three tabs: `https://github.com/` (current), `https://web.plaud.ai/` (background), `https://news.ycombinator.com/` (background)
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL switch window 1's current tab to the plaud tab
- **AND** SHALL raise window 1 to the front
- **AND** SHALL dispatch the keystroke path against the now-active plaud tab

#### Scenario: Target URL already in current tab

- **WHEN** Safari window 1's current tab is already `https://web.plaud.ai/`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL check the tab's URL and SHALL NOT make any tab current
- **AND** SHALL proceed to raise and keystroke

#### Scenario: close does not switch tabs

- **WHEN** user runs `safari-browser close --url work.example/a2` and that tab is a background tab of its window
- **THEN** no AppleScript of the command makes another tab current

##### Example: tab switch scripts

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Target | What happens to the tab before any keystroke |
| --- | --- | --- |
| `upload --native "input" f.txt --url work.example/a2` | background tab 2 of window id 5822 | one AppleScript: the URL check on `tab 2 of window id 5822`, then that tab is made current |
| `upload --native "input" f.txt --url work.example/a1` | current tab 1 of window id 5822 | one AppleScript: the URL check on `tab 1 of window id 5822`; no tab is made current |
| `upload --native "input" f.txt --window-id 5822 --tab-in-window 2` | background tab 2 of window id 5822 | one AppleScript, without a URL check; tab 2 is made current |
| `upload --native "input" f.txt --window 2` | window id 5822, no tab named | no AppleScript for this |
| `upload --native "input" f.txt --url work.example/a2`, when tab 1 is made current again after that AppleScript | tab 2 of window id 5822 | the upload stops with a target-changed error; the file input is not clicked |
| `pdf --allow-hid --url work.example/a2 out.pdf` | background tab 2 of window id 5822 | inside the export script, before the window is raised: the URL check, then tab 2 is made current |
| `pdf --allow-hid --url work.example/a1 out.pdf` | current tab 1 of window id 5822 | inside the export script: the URL check; no tab is made current |
| `close --url work.example/a2` | background tab 2 of window id 5822 | nothing; `close` makes no tab current |

### Requirement: WindowOnlyTargetOptions removal

The system SHALL expose a single `TargetOptions` parser struct to all subcommands, including those previously restricted to `WindowOnlyTargetOptions`. The `WindowOnlyTargetOptions` struct SHALL be removed. Commands that were previously window-only (`close`, `screenshot`, `pdf`, `upload --native`, `upload --allow-hid`) SHALL accept the full four-flag targeting surface through `TargetOptions` and resolve through the native path resolver.

#### Scenario: close command accepts --url

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/`
- **AND** user runs `safari-browser close --url plaud`
- **THEN** the system SHALL resolve `--url plaud` to the plaud tab and its window
- **AND** SHALL close that tab and no other tab
- **AND** SHALL NOT reject the invocation with "WindowOnly only supports --window"

#### Scenario: pdf command accepts --document

- **WHEN** Safari has two documents across two windows
- **AND** user runs `safari-browser pdf --document 2 --allow-hid /tmp/page.pdf`
- **THEN** the system SHALL resolve document 2 to its owning window
- **AND** SHALL raise that window and dispatch the PDF dialog keystroke path

##### Example: close with each targeting flag

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Tab closed |
| --- | --- |
| `close --url work.example/a2` | tab 2 of window id 5822 |
| `close --document 4` | tab 1 of window id 5822 |
| `close --tab 6` | tab 1 of window id 6933 |
| `close --window 3` | the current tab of window id 6933 |
| `close --window-id 4711 --tab-in-window 3` | tab 3 of window id 4711 |

### Requirement: Target a window by its stable id

The system SHALL accept a global `--window-id <id>` flag on every subcommand that composes the shared targeting options. The value SHALL be a positive integer naming a Safari window by its AppleScript `id of window`, which does not change while the window exists. Without `--tab-in-window`, the target SHALL be the current tab of that window: `js`, `wait` and `save-pdf` SHALL read its index once at command start and fail if a different tab becomes current (the same check `--window <n>` has); other commands SHALL address it as `document of window id <id>`, that window's current tab at each Apple event, with or without `--profile`. With `--tab-in-window <m>`, the target SHALL be the `m`-th tab of that window, referenced as `tab m of window id <id>`; `js`, `wait` and `save-pdf` SHALL check that it exists before running anything.

`--window-id` SHALL be mutually exclusive with `--window`, `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab` and `--document`; a combination SHALL be rejected with a validation error before Safari is contacted. `--tab-in-window` SHALL be accepted with either `--window` or `--window-id`. When `--profile <name>` is also given, the window SHALL belong to that profile; otherwise the command SHALL fail without acting. When no window has the given id, or the window has no tab `m`, the command SHALL fail with a document-not-found error and SHALL NOT fall back to the front window or to any other window; without `--profile` the error for a missing window SHALL list no window's tabs, the error for a missing tab SHALL list no other window's tabs, and both SHALL point at the window ids rather than at `--window <n>`. When the profile check fails, the error SHALL list only the windows of the requested profile, and when that profile has no window open it SHALL list none. A value below 1 SHALL be rejected with a validation error. `close`, `screenshot`, `pdf`, and `upload` on its native paths (`--native`, `--allow-hid`, or the default when Accessibility is granted) SHALL find the window by its id and SHALL act on it by that id, as "Window-level commands act on the window they resolved" requires. This list of commands is closed. `documents` lists every tab and `wait <ms>` / `wait --jitter` read no tab: they accept the flag and do not use it, as they do `--window <n>`.

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
- **AND** no JavaScript runs in any tab and no tab or window is changed

#### Scenario: Tab that does not exist in a window named by id

- **WHEN** user runs `safari-browser js --window-id 4711 --tab-in-window 9 "1"`
- **AND** window 4711 has three tabs
- **THEN** the command fails with a document-not-found error
- **AND** the script runs in no tab

#### Scenario: Window id outside the requested profile

- **WHEN** user runs `safari-browser get url --window-id 4711 --profile Work`
- **AND** window 4711 belongs to the profile `Personal`
- **THEN** the command fails without reading the window

#### Scenario: Window id with a profile that has no window open

- **WHEN** user runs `safari-browser get url --window-id 4711 --profile Work`
- **AND** no window of the profile `Work` is open
- **THEN** the command fails with a document-not-found error
- **AND** the error lists no tab URL of any other profile

#### Scenario: Window id combined with another targeting flag

- **WHEN** user runs `safari-browser get url --window-id 4711 --window 1`
- **THEN** the system rejects the invocation with a validation error naming both flags

#### Scenario: Window id below one

- **WHEN** user runs `safari-browser get url --window-id 0`
- **THEN** the system rejects the invocation with a validation error

#### Scenario: Window id in an exec script

- **WHEN** user runs `safari-browser exec --window-id 4711` with a script whose steps read the page
- **THEN** every step targets the current tab of window 4711 in the in-process path and in the subprocess path alike

#### Scenario: A window-level command acts on the window id it was given

- **WHEN** user runs `safari-browser close --window-id 5822 --tab-in-window 2`
- **THEN** one AppleScript closes `tab 2 of window id 5822`
- **AND** no AppleScript of the command names a window by its position

##### Example: window-level commands with a window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window. Window 1 belongs to the profile `Home`, windows 2 and 3 to the profile `Work`.

| Command | Result |
| --- | --- |
| `close --window-id 5822` | the current tab of window id 5822 is closed |
| `close --window-id 5822 --tab-in-window 2` | tab 2 of window id 5822 is closed; tab 1 stays the current tab |
| `close --window-id 9999` | document-not-found; nothing is closed |
| `close --window-id 5822 --tab-in-window 9` | document-not-found; nothing is closed |
| `close --window-id 4711 --profile Work` | the command fails; nothing is closed |

### Requirement: Window number resolved to its id at command start

The commands in the closed list below SHALL resolve `--window <n>`, and `--window <n> --tab-in-window <m>`, to the stable id of the window that is the `n`-th window when the command starts, once, after the command's own argument checks and before any other Apple event of the command, and SHALL then address that window as `--window-id <id>` addresses it (see "Target a window by its stable id"): without `--tab-in-window`, the current tab of that window at each Apple event; with `--tab-in-window <m>`, `tab <m> of window id <id>`, where `<m>` stays a position inside that window at each Apple event (#188). No AppleScript sent after the id was read SHALL address the target window by its position; an enumeration that lists every window is not addressing the target. `--window <n>` keeps its meaning: `n` counts windows from the front, and with `--profile <name>` it counts only that profile's windows, at the moment the command starts. Nine checks SHALL be made before the pin, and so before Safari is contacted; the list is closed, and only these nine are moved or kept in front of it: (1) a `scroll` direction; (2) a `set media` scheme; (3) a `press` with no key name; (4) a `find` locator; (5) an `exec` script whose `--script` file does not exist, or that does not parse or exceeds `--max-steps`; (6) `upload`'s check that the file exists; (7) `upload`'s 10 MB limit, when it takes its JavaScript path by default (with `--js` that limit is checked at parse time); (8) `pdf`'s refusal when `--allow-hid` is absent, and its checks of the destination; (9) `screenshot`'s checks of the GUI session, of the Screen Recording permission, and of Accessibility when `--element` or `--content-only` is given. The daemon's validation of a script-run request (its envelope, its script, and whether a step's command and arguments are ones it runs in-process) also comes before the attempt the daemon makes; it belongs to script-exec and is not part of this list. `find` still makes its action check ("Action must be click or fill") and its text check ("fill action requires text argument") after its lookup has run in Safari, as it did before this requirement, which does not cover them. Checks made by ArgumentParser's `validate()` run at parse time and are not part of this rule.

Without `--profile`, the id SHALL be read with one query that names window `n` (with `--tab-in-window <m>`, the same query SHALL also read the window's tab count, and the id SHALL be used only when `1 <= m <= tab count`); the query SHALL NOT probe for dialogs. With `--profile`, the id SHALL be the one a single profile-scoped enumeration reads for that window (for `--tab-in-window <m>`, the enumeration's tab `m` of that window), without a dialog probe; that enumeration SHALL be the profile check for the whole command, and later Apple events of the command SHALL NOT enumerate again to check the id against the profile (a window's profile does not change while it is open). Only a check made by the process that sends the Apple events SHALL count as that check. The private record of `<n>` that `exec` hands to each step with `--window-id <id>` words a miss; it SHALL NOT be taken as proof that the id belongs to the profile, whether it arrives in a command's arguments or in a request to the daemon. An id that arrives with that record under `--profile` SHALL be checked against the profile by its receiver before anything is read from or written to that window: once, when the command starts, by a command in the closed list below; once per request, by the daemon when it runs a script, and before the tab-ownership marker reads the title when the request carries one; and, by a command outside the list, exactly as a `--window-id <id>` the user typed is checked.

When the id cannot be read — no `n`-th window, a window with no tab, a tab `m` outside the window, an enumeration record without a window id, or, without `--profile`, a query that does not answer — the command SHALL keep the positional target, so that its first step fails, or runs, exactly as it did before this requirement, and SHALL write one note to stderr saying that `--window <n>` is looked up by its position at each step. `exec` is the one exception to the note: when its script is handed to the daemon, `exec` SHALL NOT write the note for its own failed read, because the daemon makes one more attempt (see script-exec, "Shared target resolution"); the note is then written only if that attempt fails too. Under `--profile`, an enumeration that times out or fails SHALL be reported as the command's error, not retried by the first step; for `exec` that command is `exec` itself, so no step runs and no per-step result is printed (see script-exec, "Shared target resolution"). `tab is-marked` and `tab unmark` SHALL report it with the exit status they give any other error, 2, and never with 1, which `tab is-marked` gives for a tab that carries no marker; the same holds for an id of another profile refused at command start. A cancelled command SHALL stop instead.

When the window whose id was read closes before a later step, or the tab `m` of it is gone, that step SHALL fail with a document-not-found error and SHALL NOT act on the window now in position `n`, on the front window, or on any other window. The error's pattern SHALL begin with `window <n> (window id <id> at command start)` (with `--tab-in-window`, `window <n> tab <m> (window id <id> at command start)`); it SHALL end with ` (profile: "<name>")` in two cases only, a closed list: (1) the check against `--profile` of an id at command start fails, because the id is not one of that profile's windows (this is what an `exec` step, or the daemon, reports for an id of another profile), and (2) a `js`, `wait` or `save-pdf` step under `--profile` cannot read the window's current tab. A pinned window that closes after the pin SHALL NOT get the suffix. The error's listing and hint SHALL be those of item 8 of "Document not found surfaces discoverable error". `js`, `wait` and `save-pdf` steps of an `exec` run that receive the resolved id SHALL name `<n>` the same way. Commands that resolve `--profile` once and pass no profile to their later calls (`get text`, `get html`, `save-image`, `upload` on its JavaScript path, `open`) list, for a window that is gone, the note of a window that is gone, not the profile's tabs.

The commands are a closed list: `back`, `check`, `uncheck`, `click`, `close`, `console`, `cookies get`, `cookies set`, `cookies clear`, `dblclick`, `drag`, `errors`, `fill`, `find`, `focus`, `forward`, every `get` subcommand, `highlight`, `hover`, every `is` subcommand, every `mouse` subcommand, `open` when it navigates (not `--new-tab` or `--new-window`), `pdf`, `press`, `reload`, `save-image`, `screenshot`, `scroll`, `scrollintoview`, `select`, `set media`, `snapshot`, every `storage` subcommand, `tab is-marked`, `tab unmark`, `type`, `upload`, and `exec` (only when some step, or the tab-ownership marker, uses the exec-level target). `close`, `pdf`, `screenshot`, and `upload` on its native paths then act as "Window-level commands act on the window they resolved" requires. The exceptions are also a closed list, each for its own reason: `js`, `wait` and `save-pdf` already resolve `--window <n>` once at command start and additionally require the current tab not to change; `tabs`, `tab focus`, `tab new` and `open --new-tab` read the window's id themselves before acting; `tab <n>` with `--window <n>` and no `--profile` switches the tab in a single Apple event that names the window by its position (with `--profile` it uses the id the profile-scoped enumeration read); `pdf-cache get` reads one tab URL through a seam its tests inject, and nothing after it addresses the window; `open --new-window`, `documents` and `wait <ms>` read or act on no existing tab; and a command given no targeting flag keeps the front window, looked up at each Apple event (safari-browser#287). A command added later that composes the shared targeting options SHALL resolve `--window <n>` this way or be added to this list of exceptions.

`click --mark-tab` (and `--mark-tab-persist`) SHALL resolve the id before it reads and rewrites the title, so the wrap, the click and the unwrap address the same window by id.

`save-image` checks its target once before it reads the element. For `save-image --window <n>` without `--tab-in-window` and without `--profile`, that check SHALL be one query that names the window by the id read at command start and asks for its position, bounded at 2 seconds, and SHALL NOT enumerate the windows. A not-found answer to that query SHALL be the document-not-found error above, with the note of a window that is no longer open. Any other failure of it (a timeout, for instance) SHALL be the command's error, and the element SHALL NOT be read; before this requirement a failed id read at that point was ignored and the command went on.

The id read at command start is not carried to the next command: a second command started with `--window <n>` reads the `n`-th window again.

#### Scenario: A window raised mid-command does not redirect later steps

- **WHEN** user runs `safari-browser click --mark-tab --window 2 "#go"`
- **AND** window 2 has id 4711 when the command starts
- **AND** another window is raised to position 2 after the first Apple event
- **THEN** the title is read and wrapped, the element is clicked, and the title is unwrapped in `window id 4711`
- **AND** no AppleScript sent after the id was read addresses `window 2`

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
- **THEN** the command writes one note that `--window 5` is looked up by its position, keeps it as a position, and fails with the document-not-found error that lists the open windows, as it did before this requirement

#### Scenario: A tab outside the window at command start

- **WHEN** user runs `safari-browser get url --window 1 --tab-in-window 9` and window 1 has three tabs
- **THEN** the command keeps the positional target and fails with the document-not-found error it reported before this requirement

#### Scenario: Window number within a profile

- **WHEN** user runs `safari-browser click --mark-tab --window 1 --profile Work "#go"`
- **AND** the first window of the profile `Work` is Safari's window 3, whose id is 4711
- **THEN** the id 4711 is read from one profile-scoped enumeration at command start
- **AND** the title reads and writes and the click address `window id 4711` without enumerating the windows again

#### Scenario: A resolved id of another profile is refused by its receiver

- **GIVEN** window id 4711 belongs to profile `Home`
- **WHEN** the daemon receives a script-run request whose target is `--window-id 4711` with the private record of window number 1 and `--profile Work`
- **THEN** no step SHALL read from window 4711 and its title SHALL NOT be rewritten
- **AND** each step that uses the request's target SHALL fail with a document-not-found error whose pattern is `window 1 (window id 4711 at command start) (profile: "Work")`; a request that carries the tab-ownership marker SHALL fail as a whole with that error
- **AND** the same arguments given to `get url` SHALL fail the same way before any tab is read

#### Scenario: A stuck Safari under a profile

- **WHEN** user runs `safari-browser get url --window 1 --profile Work` and the enumeration at command start times out
- **THEN** the command fails with that timeout after one enumeration

#### Scenario: The marker probes keep their exit status when the pin fails

- **WHEN** user runs `safari-browser tab is-marked --window 1 --profile Work` or `safari-browser tab unmark --window 1 --profile Work` and the enumeration at command start times out
- **THEN** the command exits with status 2 and reads no title
- **AND** `tab is-marked` SHALL NOT exit with status 1, which means the tab carries no marker

#### Scenario: save-image cannot read the position of the pinned window

- **WHEN** user runs `safari-browser save-image out.png --element img --window 2`, window 2 has id 4711 when the command starts, and the query for the position of window id 4711 times out
- **THEN** the command fails with that timeout and reads no element

#### Scenario: A window-level miss that nothing checked

- **WHEN** user runs `safari-browser get url --window 2`, window 2 has id 4711 when the command starts, and the read of the current tab of window id 4711 answers that the object was not found
- **THEN** the command fails with a document-not-found error whose pattern is `window 2 (window id 4711 at command start)`
- **AND** its one note says that the window, or its current tab, could not be found, and does not say that the window is no longer open
- **AND** no AppleScript is sent after the failed read

#### Scenario: Other targeting flags are not resolved

- **WHEN** user runs a listed command with `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--document`, `--tab`, `--window-id`, `--profile` alone, or no targeting flag
- **THEN** no AppleScript is sent to resolve a window id before the command's own steps

#### Scenario: A window-level command resolves the window number at command start

- **WHEN** user runs `safari-browser close --window 2`, `safari-browser pdf --allow-hid --window 2 out.pdf`, `safari-browser upload --native "input" f.txt --window 2` or `safari-browser screenshot --window 2 out.png`
- **AND** window 2 has id 5822 when the command starts
- **THEN** the id is read once, before any other Apple event of the command
- **AND** no AppleScript sent after it names `window 2`

##### Example: window-level commands and the window number

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | What happens after the first AppleScript | Result |
| --- | --- | --- |
| `close --window 2` | window 3 is raised to the front, so window id 5822 is now window 3 | the close script names `window id 5822` |
| `close --window 2` | window id 5822 closes | document-not-found with the pattern `window 2 (window id 5822 at command start)`; nothing is closed |
| `close --window 2 --tab-in-window 2` | nothing | the close script names `tab 2 of window id 5822` |
| `pdf --allow-hid --window 2 out.pdf` | nothing | the export script names `window id 5822` and never `window 2` |
| `upload --native "input" f.txt --window 2` | nothing | the read that checks the target, the click and the dialog script name `window id 5822` |
| `screenshot --window 2 out.png` | nothing | the bounds and the title are read from `window id 5822` |
| `close --window 2`, when the id of window 2 cannot be read | nothing | one note; the close script names `window 2` |
| `close --window 1 --profile Work` (windows 2 and 3 belong to `Work`) | nothing | the windows are enumerated once in the whole command; the close script names `window id 5822` |
