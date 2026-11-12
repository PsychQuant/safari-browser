## MODIFIED Requirements

### Requirement: Tab auto-switch classified as transitively authorized interference

When a window-only primitive (`upload --native`, `upload --allow-hid`, `pdf`) resolves a target via `--url`, `--tab`, or `--document` and the target document resides in a non-current tab of its owning window, the system SHALL treat the subsequent tab switch (`set current tab of window id <id> to tab <t> of window id <id>`, or the same statement with the window's position when no window id is available) as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag. The system SHALL NOT require a separate opt-in flag for tab switching.

The stderr interference warning emitted before keystroke dispatch SHALL include a note that the target tab will be briefly switched if it is not currently active.

#### Scenario: Tab switch accompanies native upload to background tab

- **WHEN** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud` and the plaud document is in a background tab of its owning window
- **THEN** the system SHALL emit a stderr warning indicating that keyboard control is active AND that the target tab will be brought to the front of its window
- **AND** SHALL perform the tab switch as part of the keystroke dispatch sequence

#### Scenario: No tab switch warning when target is already current

- **WHEN** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud` and the plaud document is already the current tab of its owning window
- **THEN** the system SHALL emit the standard keystroke interference warning without a tab-switch addendum
- **AND** SHALL NOT issue a `set current tab` AppleScript command

##### Example: tab switch notice and script

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Notice on stderr before the keyboard warning | Tab switch |
| --- | --- | --- |
| `upload --native "input" f.txt --url work.example/a2` | says the target tab will be brought to the front of its window | `set current tab of window id 5822 to` tab 2 of that window |
| `upload --native "input" f.txt --url work.example/a1` | none | none |
| `pdf --allow-hid --url work.example/a2 out.pdf` | says the target tab will be brought to the front of its window | inside the export script |

### Requirement: Spatial interference gradient for focus-existing

When a command (such as `open <url>` in its default focus-existing mode) needs to reveal an existing Safari tab that is not currently focused, the system SHALL classify the interference level based on the spatial relationship between the target tab and the currently frontmost Safari context. The classification SHALL map to concrete behavior according to the following gradient:

| Spatial layer | Condition | Behavior | Interference classification |
|---------------|-----------|----------|----------------------------|
| 1. Already focused | Target is the current tab of the front window | No AppleScript action | Non-interfering |
| 2. Same window | Target is a background tab within the front window | One AppleScript: check that the tab still shows the requested URL, then `set current tab of window id <id> to tab <t> of window id <id>` | Passively interfering, transitively authorized by the invoking command's semantics (no new opt-in flag required) |
| 3. Same Space | Target is in a different window sharing the caller's current macOS Space | One AppleScript that names the window by its id: check that the tab still shows the requested URL, switch its current tab if needed, raise the window and activate Safari | Passively interfering; stderr warning SHALL be emitted |
| 4. Cross-Space | Target is in a window on a different macOS Space | Do NOT raise across Space; fall back to opening a new tab in the current Space | Non-interfering (the cross-Space target is left undisturbed) |

Space membership SHALL be detected via the CGWindow API (`kCGWindowWorkspace` or equivalent). If Space detection fails due to missing permissions, the system SHALL default to the same-Space behavior (layer 3, raise window) rather than introduce unauthorized cross-Space interference, and SHALL emit a stderr note that Space detection was unavailable.

This gradient SHALL apply uniformly to every command that performs focus-existing, not only `open`.

#### Scenario: Layer 1 — target already focused is a no-op

- **WHEN** user runs `safari-browser open https://example.com/` and the front window's current tab is already at `https://example.com/`
- **THEN** the system SHALL NOT issue any AppleScript navigation or window-activation command
- **AND** stdout/stderr SHALL contain no interference warnings

#### Scenario: Layer 2 — same-window tab switch is passive and silent

- **WHEN** user runs `safari-browser open https://b.example/` and the front window has two tabs (`a.example` current, `b.example` background)
- **THEN** the system SHALL switch the front window's current tab to the `b.example` tab
- **AND** SHALL NOT emit a stderr interference warning
- **AND** the user's typing in other applications SHALL NOT be disrupted

#### Scenario: Layer 3 — cross-window raise emits stderr warning

- **WHEN** the target tab exists in window 2 and window 1 is currently frontmost, both in the same Space
- **THEN** the system SHALL activate window 2 (bringing it to front)
- **AND** SHALL switch window 2's current tab to the target tab if the target is not already current within window 2
- **AND** stderr SHALL contain a warning mentioning that a background window was raised

#### Scenario: Layer 4 — cross-Space target triggers new-tab fallback

- **WHEN** the target tab exists in window 3 which is on macOS Space B
- **AND** the caller's current context is on Space A
- **AND** CGWindow API successfully reports the window is on Space B
- **THEN** the system SHALL NOT raise window 3 or switch Space
- **AND** SHALL open a new tab in the front window of Space A navigated to the target URL
- **AND** stderr SHALL contain a note indicating an existing tab exists on another Space and was left undisturbed

#### Scenario: Space detection failure falls back to layer 3

- **WHEN** the CGWindow API call to determine a window's Space membership fails (e.g., screen recording permission denied)
- **AND** a focus-existing operation needs to classify a cross-window target
- **THEN** the system SHALL proceed as if the target is in the same Space (layer 3: raise window)
- **AND** stderr SHALL contain a note indicating Space detection was unavailable and suggesting the screen recording permission

#### Scenario: Gradient applies to any focus-existing invocation

- **WHEN** a future command beyond `open` invokes focus-existing semantics (e.g., a hypothetical `focus` subcommand)
- **THEN** its interference classification SHALL follow the same spatial gradient defined here
- **AND** SHALL NOT redefine the gradient behavior locally

##### Example: gradient actions by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window. Window 1 is the front window.

| Target tab | Layer | Tab made current | Window raised | Warning on stderr |
| --- | --- | --- | --- | --- |
| tab 1 of window id 4711 | 1 | no | no | no |
| tab 3 of window id 4711 | 2 | tab 3 of window id 4711 | no | no |
| tab 2 of window id 5822, same Space | 3 | tab 2 of window id 5822 | window id 5822 | yes |
| tab 1 of window id 6933, another Space | 4 | no | no | a note; a new tab opens in the front window |
| tab 2 of window id 5822, which shows another URL when the AppleScript runs | 3 | no | no | the command fails with a target-changed error |
