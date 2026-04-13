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

### Requirement: Explicit opt-in for interfering operations

Commands that require Human Interface Device (HID) control, system dialogs, or other interfering behavior MUST require an explicit opt-in flag. The CLI MUST NOT perform interfering operations unless the user has passed the corresponding flag.

The following opt-in flags are defined:

| Flag | Permits |
|---|---|
| `--allow-hid` | Keyboard/mouse control via System Events |
| `--native` | Native file dialog interaction via System Events |

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
