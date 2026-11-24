## MODIFIED Requirements

### Requirement: Spatial interaction gradient

When a command must reveal a target tab that is not currently focused, it SHALL choose the action based on the spatial relationship between the invocation context and the target tab. The gradient has four layers, applied in order:

1. **Target is front tab of front window** — no action; the tab is already visible.
2. **Target is a background tab within the same window** — switch tab within the window with one AppleScript that names the window by its id (`set current tab of window id <id> to tab <t> of window id <id>`), after that AppleScript has checked that the tab still shows the requested URL. This action is classified as passively interfering and transitively authorized under the command's existing semantics (no new opt-in flag required).
3. **Target is in a different window within the same macOS Space** — with one AppleScript that names the window by its id: check that the tab still shows the requested URL, make it the window's current tab when it is not, raise the window to the front and activate Safari. This action is classified as passively interfering; an `stderr` warning SHALL be emitted after the window was raised, and SHALL NOT be emitted when the reveal fails.
4. **Target is in a window on a different macOS Space** — do NOT perform cross-Space raise. Instead, fall back to opening a new tab in the current Space's front window (or the inferred user-active window).

Layers 2 and 3 follow "Window-level commands act on the window they resolved" of document-targeting. When the tab no longer shows the requested URL the command SHALL fail with a target-changed error and change nothing; when the window is no longer open it SHALL fail with a document-not-found error. When the window is open but has no tab at that position any more, it SHALL fail with a document-not-found error too. In none of these cases SHALL it open a new tab. When the enumeration read no id for the window, the same one AppleScript, with the same checks, names the window by its position; a window id of zero or less counts as no id.

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

#### Scenario: The matching tab moved before it was revealed

- **WHEN** user runs `safari-browser open https://work.example/a2`, the enumeration finds that URL in tab 2 of window id 5822, and tab 2 of that window shows another URL when the AppleScript runs
- **THEN** the command fails with a target-changed error
- **AND** no tab is made current, no window is raised and no new tab is opened

##### Example: focus-existing by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window. Window 1 is the front window.

| Command | Layer | AppleScript sent after the enumeration |
| --- | --- | --- |
| `open https://home.example/1` | 1 | none |
| `open https://home.example/3` | 2 | one: the URL check on `tab 3 of window id 4711`, then that tab is made current; no `set index`, no `activate` |
| `open https://work.example/a2`, same Space | 3 | one: the URL check on `tab 2 of window id 5822`, that tab is made current, `set index of window id 5822 to 1`, `activate`; one warning on stderr |
| `open https://work.example/b1`, same Space | 3 | one: the URL check on `tab 1 of window id 6933`, `set index of window id 6933 to 1`, `activate`; no tab is made current |
| `open https://work.example/b1`, window 3 on another Space | 4 | a new tab in the front window; window id 6933 is not named |
| `open https://work.example/a2`, same Space, when tab 2 of window id 5822 shows another URL by the time the AppleScript runs | 3 | one, which fails its URL check: a target-changed error; no tab is made current, no window is raised, no new tab is opened, and no warning is written |
