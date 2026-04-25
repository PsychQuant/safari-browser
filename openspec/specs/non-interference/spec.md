# non-interference Specification

## Purpose

Cross-cutting design principle ensuring all safari-browser commands default to non-interference — users can do other things on their computer simultaneously without disruption. HID control, system dialogs, and other interfering operations require explicit opt-in.

## Requirements

### Requirement: Default non-interference

All safari-browser commands SHALL execute without interfering with the user's concurrent use of the computer. By default, commands MUST NOT:

1. Control the mouse cursor or simulate mouse events via System Events
2. Control the keyboard or simulate keystrokes via System Events
3. Display system dialogs, file choosers, or modal windows
4. Produce audible sounds (e.g., screenshot shutter)
5. Steal window focus or bring Safari to the foreground (unless the command's purpose requires Safari to be visible, such as `open --new-window`)

Commands that fulfill their purpose entirely through AppleScript `do JavaScript`, AppleScript `set URL`, or silent system utilities (e.g., `screencapture -x`) SHALL be classified as non-interfering.

#### Scenario: JS-based command does not interfere

- **WHEN** a user runs `safari-browser click "button.submit"` while typing in another application
- **THEN** the click is executed via JavaScript in Safari without moving the mouse cursor, stealing keyboard focus, or producing any sound, and the user's typing in the other application is uninterrupted

#### Scenario: Screenshot is silent

- **WHEN** a user runs `safari-browser screenshot /tmp/test.png`
- **THEN** the screenshot is captured using `screencapture -x` (silent mode) without producing the macOS shutter sound

#### Scenario: Channel monitor does not activate by default

- **WHEN** the safari-browser channel server starts without `SB_CHANNEL_MONITOR=1`
- **THEN** no periodic screenshots are taken and no VLM inference runs

---
### Requirement: Explicit opt-in for interfering operations

Commands that require Human Interface Device (HID) control, system dialogs, or other interfering behavior MUST require an explicit opt-in flag. The CLI MUST NOT perform interfering operations unless the user has passed the corresponding flag.

The following opt-in flags are defined:

| Flag | Permits |
|---|---|
| `--allow-hid` | Keyboard/mouse control via System Events |
| `--native` | Native file dialog interaction via System Events |
| `--mark-tab` / `--mark-tab-persist` | Wraps target tab title with the zero-width ownership marker — passively interfering when opted in. See `tab-ownership-marker` capability. |

Future commands that introduce new categories of interference MUST define a new opt-in flag or reuse an existing one if the interference category matches.

#### Scenario: Upload defaults to JS injection

- **WHEN** a user runs `safari-browser upload "input[type=file]" /path/to/file.pdf` without flags
- **THEN** the file is injected via JavaScript DataTransfer API without opening a file dialog or controlling the keyboard

#### Scenario: Upload with --native uses file dialog

- **WHEN** a user runs `safari-browser upload "input[type=file]" /path/to/file.pdf --native`
- **THEN** the command opens the native macOS file dialog and uses System Events keystroke to navigate to the file path

#### Scenario: PDF export requires --allow-hid

- **WHEN** a user runs `safari-browser pdf /tmp/page.pdf` without `--allow-hid`
- **THEN** the command exits with an error indicating that `--allow-hid` is required

---
### Requirement: Interference warning on stderr

When a command activates an interfering operation (via an opt-in flag), it MUST emit a warning to stderr before the interfering operation begins. The warning MUST indicate:

1. What type of interference will occur (e.g., "keyboard control", "file dialog")
2. That the user's input devices will be temporarily unavailable

The warning MUST NOT be emitted to stdout (to avoid polluting command output).

#### Scenario: HID warning before keyboard control

- **WHEN** a user runs `safari-browser upload "input" /path/to/file --allow-hid` and JS injection fails
- **THEN** before activating System Events, the command emits a warning to stderr: a message indicating HID keyboard control is active

#### Scenario: No warning for non-interfering commands

- **WHEN** a user runs `safari-browser click "button"` (non-interfering, JS-based)
- **THEN** no interference warning is emitted to stderr

---
### Requirement: Conformance classification for new commands

Every new safari-browser command or flag MUST be classified into one of three interference levels before implementation:

| Level | Definition | Opt-in required |
|---|---|---|
| **Non-interfering** | Uses only JS, AppleScript property access, or silent utilities | No |
| **Passively interfering** | Produces visible side effects (e.g., window focus change) but does not control input devices | No, but MUST document the side effect |
| **Actively interfering** | Controls mouse, keyboard, or displays system dialogs | Yes — MUST require opt-in flag |

#### Scenario: New command classified before merge

- **WHEN** a developer proposes a new command that uses System Events `keystroke`
- **THEN** the command is classified as "actively interfering" and MUST include an opt-in flag in its design

---
### Requirement: Tab auto-switch classified as transitively authorized interference

When a window-only primitive (`upload --native`, `upload --allow-hid`, `pdf`) resolves a target via `--url`, `--tab`, or `--document` and the target document resides in a non-current tab of its owning window, the system SHALL treat the subsequent `set current tab of window N to tab T` AppleScript operation as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag. The system SHALL NOT require a separate opt-in flag for tab switching.

The stderr interference warning emitted before keystroke dispatch SHALL include a note that the target tab will be briefly switched if it is not currently active.

#### Scenario: Tab switch accompanies native upload to background tab

- **WHEN** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud` and the plaud document is in a background tab of its owning window
- **THEN** the system SHALL emit a stderr warning indicating that keyboard control is active AND that the target tab will be brought to the front of its window
- **AND** SHALL perform the tab switch as part of the keystroke dispatch sequence

#### Scenario: No tab switch warning when target is already current

- **WHEN** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud` and the plaud document is already the current tab of its owning window
- **THEN** the system SHALL emit the standard keystroke interference warning without a tab-switch addendum
- **AND** SHALL NOT issue a `set current tab` AppleScript command

---
### Requirement: Screenshot Accessibility path remains non-interfering for background windows

When the screenshot command resolves a target via `--url`, `--tab`, or `--document` to a non-frontmost window and Accessibility permission is granted, the system SHALL classify the capture as non-interfering: it SHALL NOT raise the target window, SHALL NOT switch the active Space, SHALL NOT produce a shutter sound, and SHALL NOT emit an interference warning to stderr.

#### Scenario: Background-window screenshot is fully non-interfering

- **WHEN** the user is typing in a non-Safari application
- **AND** user runs `safari-browser screenshot --url plaud /tmp/plaud.png` while the plaud window is a Safari background window
- **AND** Accessibility permission is granted
- **THEN** the screenshot SHALL be captured silently via `screencapture -x -R`
- **AND** the user's typing in the other application SHALL be uninterrupted
- **AND** no window SHALL be raised, focused, or moved between Spaces
- **AND** no stderr warning SHALL be emitted

---
### Requirement: Spatial interference gradient for focus-existing

When a command (such as `open <url>` in its default focus-existing mode) needs to reveal an existing Safari tab that is not currently focused, the system SHALL classify the interference level based on the spatial relationship between the target tab and the currently frontmost Safari context. The classification SHALL map to concrete behavior according to the following gradient:

| Spatial layer | Condition | Behavior | Interference classification |
|---------------|-----------|----------|----------------------------|
| 1. Already focused | Target is the current tab of the front window | No AppleScript action | Non-interfering |
| 2. Same window | Target is a background tab within the front window | `set current tab of window N to tab T` | Passively interfering, transitively authorized by the invoking command's semantics (no new opt-in flag required) |
| 3. Same Space | Target is in a different window sharing the caller's current macOS Space | Activate that window and, if needed, switch its current tab | Passively interfering; stderr warning SHALL be emitted |
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

<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Daemon process is passively interfering and user-terminable

When the user opts into daemon mode, the resulting long-running `safari-browser` daemon process SHALL be classified as "passively interfering" — the daemon MUST NOT control HID input, MUST NOT open system dialogs, MUST NOT emit sounds, and MUST NOT steal window focus. The user MUST be able to terminate the daemon at any time through at least two mechanisms: (a) running `safari-browser daemon stop`, and (b) waiting out the idle timeout defined in the `persistent-daemon` capability.

#### Scenario: Daemon does not steal focus on startup

- **WHEN** the user runs `safari-browser daemon start` from a Terminal while working in another application
- **THEN** no window or dialog comes to the foreground and the user's current application retains focus

#### Scenario: Explicit stop terminates daemon immediately

- **WHEN** the user runs `safari-browser daemon stop` while a daemon is running
- **THEN** the daemon process exits within 5 seconds, removes its socket and pid files, and further CLI invocations without `--daemon` behave identically to pre-daemon state

#### Scenario: Idle timeout terminates daemon without user action

- **WHEN** no request reaches the daemon for the configured idle timeout duration
- **THEN** the daemon exits on its own, restoring the non-interference default state automatically


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
  - .remember/tmp/save-session.pid
-->

---
### Requirement: Daemon mode does not lower the default non-interference guarantees

Enabling daemon mode MUST NOT cause any individual command to perform a more interfering action than the same command would perform in stateless mode. Specifically, daemon mode MUST NOT: cache stale window state that causes the daemon to raise a window the user has since backgrounded, skip the spatial-gradient layering defined in the `human-emulation` capability, or perform any pre-emptive tab activation in the absence of an explicit command.

#### Scenario: Daemon respects Layer 1 noop

- **WHEN** daemon mode is enabled and a command targets the tab that is already the front tab of the front window
- **THEN** the daemon performs the same noop as the stateless path — no `activate window` AppleScript is issued

<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
  - .remember/tmp/save-session.pid
-->