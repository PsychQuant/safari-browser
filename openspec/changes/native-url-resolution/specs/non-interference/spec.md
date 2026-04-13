## ADDED Requirements

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
