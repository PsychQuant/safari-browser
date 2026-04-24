# file-upload Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Upload file via file dialog

The system SHALL use the native macOS file dialog by default when Accessibility permission is granted. When Accessibility permission is NOT granted, the system SHALL automatically fall back to JS DataTransfer injection with a stderr warning.

The native file dialog path SHALL:
1. Use clipboard paste (`Cmd+V`) instead of `keystroke` for path input
2. Save and restore the user's clipboard content before and after the paste
3. Use `repeat until exists` polling instead of fixed `delay` for all dialog state transitions
4. Use `AXDefault` button attribute to click the confirm button (locale-independent), with `keystroke return` as fallback

The `--js` flag SHALL force JS DataTransfer regardless of permission state. The `--native` and `--allow-hid` flags SHALL be kept for backward compatibility.

When using the `--js` path, the system SHALL check `window.location.href` every 10 chunks (not every chunk) to detect page navigation, comparing only the portion before the `#` fragment. On navigation detection, the system SHALL clean up `window.__sbUpload` before aborting.

#### Scenario: Upload with Accessibility permission

- **WHEN** user runs `safari-browser upload "input[type=file]" "/path/to/file"` and Accessibility permission is granted
- **THEN** the system uses native file dialog with clipboard path input, completing in under 2 seconds of keyboard control

#### Scenario: Upload without Accessibility permission

- **WHEN** user runs `safari-browser upload "input[type=file]" "/path/to/file"` and Accessibility permission is NOT granted
- **THEN** the system falls back to JS DataTransfer with a stderr message indicating how to enable native upload via System Settings

#### Scenario: Clipboard preserved during upload

- **WHEN** user has text "important data" in clipboard and runs upload
- **THEN** after upload completes, the clipboard contains "important data" (restored)

#### Scenario: JS upload detects navigation

- **WHEN** user runs `safari-browser upload --js "input" "/path"` and navigates away during chunking
- **THEN** the system cleans up `window.__sbUpload` and aborts with error message showing old and new URLs (ignoring fragment differences)

---
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

---
### Requirement: Upload command preserves 10 MB JS hard cap under targeting flags

The system SHALL enforce the existing 10 MB hard cap on `--js` execution path (established by #24) regardless of targeting flags. When the user supplies targeting flags (`--url`, `--tab`, `--document`) without explicit `--native` / `--allow-hid` / `--js`, the system SHALL continue to route the upload through `--native` by default, not fall back to the capped `--js` path.

#### Scenario: Large file with --url routes through native by default

- **WHEN** user runs `safari-browser upload "input" "/tmp/131MB.mp3" --url plaud` without `--js`, `--native`, or `--allow-hid`
- **AND** Accessibility permission is granted
- **THEN** the system SHALL route the upload through the native file dialog path (not JS DataTransfer)
- **AND** SHALL resolve `--url plaud` via the native path resolver
- **AND** SHALL NOT trigger the 10 MB `--js` cap error

<!-- @trace
source: clipboard-path-input
updated: 2026-04-07
code:
-->
