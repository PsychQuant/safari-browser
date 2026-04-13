## ADDED Requirements

### Requirement: Upload command accepts full TargetOptions on all execution paths

The `upload` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags regardless of whether the execution path is `--js` (JavaScript DataTransfer) or `--native` / `--allow-hid` (System Events keystrokes). When targeting flags are supplied alongside `--native` or `--allow-hid`, the system SHALL resolve the target to a physical window index via the native path resolver, switch to the target tab if needed, raise that window to the front, and dispatch the file-dialog keystroke sequence against the resolved window.

The `upload` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time when `--native` or `--allow-hid` is also specified.

#### Scenario: upload --native --url resolves to target window

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/`
- **AND** user runs `safari-browser upload --native "input[type=file]" "/tmp/audio.mp3" --url plaud`
- **THEN** the system SHALL resolve `--url plaud` to the plaud window index
- **AND** SHALL raise the plaud window to the front
- **AND** SHALL perform the clipboard-paste file-dialog keystroke sequence against that window

#### Scenario: upload --native --url fails for non-matching pattern

- **WHEN** Safari has no window whose URL contains `xyz`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url xyz`
- **THEN** the system SHALL throw `documentNotFound` with `pattern: "xyz"` and the available document URLs
- **AND** SHALL NOT attempt any keystroke dispatch

#### Scenario: upload --native --url fails for ambiguous pattern

- **WHEN** Safari has two plaud windows with URLs `https://web.plaud.ai/file/a` and `https://web.plaud.ai/file/b`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL throw `ambiguousWindowMatch` listing both matches
- **AND** SHALL NOT attempt any keystroke dispatch

### Requirement: Upload command preserves 10 MB JS hard cap under targeting flags

The system SHALL enforce the existing 10 MB hard cap on `--js` execution path (established by #24) regardless of targeting flags. When the user supplies targeting flags (`--url`, `--tab`, `--document`) without explicit `--native` / `--allow-hid` / `--js`, the system SHALL continue to route the upload through `--native` by default, not fall back to the capped `--js` path.

#### Scenario: Large file with --url routes through native by default

- **WHEN** user runs `safari-browser upload "input" "/tmp/131MB.mp3" --url plaud` without `--js`, `--native`, or `--allow-hid`
- **AND** Accessibility permission is granted
- **THEN** the system SHALL route the upload through the native file dialog path (not JS DataTransfer)
- **AND** SHALL resolve `--url plaud` via the native path resolver
- **AND** SHALL NOT trigger the 10 MB `--js` cap error
