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

When using the `--js` path, the system SHALL check `window.location.href` every 10 chunks (not every chunk) to detect page navigation, comparing only the portion before the `#` fragment. On navigation detection, the system SHALL clean up the chunk buffer (`window.__sbUploadChunks`) before aborting. The error SHALL show the old and new URLs redacted as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and SHALL say so when the two look the same once redacted.

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
- **THEN** the system cleans up `window.__sbUploadChunks` and aborts with an error message showing the old and new URLs without their query strings (ignoring fragment differences)
- **AND** when the two URLs look the same once redacted, the message says that they differ in a part that is not shown

---
### Requirement: Upload command accepts full TargetOptions on all execution paths

The `upload` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags regardless of whether the execution path is `--js` (JavaScript DataTransfer) or `--native` / `--allow-hid` (System Events keystrokes). When targeting flags are supplied and the upload takes a native path (`--native`, `--allow-hid`, or the default when Accessibility is granted), the system SHALL resolve the target through the native path resolver, after `--window <n>` was resolved to the window's id at command start (document-targeting, "Window number resolved to its id at command start"), and SHALL name the window `window id <id>` in every later step (document-targeting, "Window-level commands act on the window they resolved"): the AppleScript that checks a tab the resolution names and makes it current when it is not, the read that checks the target exists and the click on the file input (both made only while a named tab is still the window's current tab), and the script that raises the window and sends the keystrokes. When the tab was found by its URL, the URL that read returns SHALL still satisfy the flag; otherwise the upload SHALL stop with a target-changed error and SHALL NOT click the file input.

In its first Safari block, before it raises the window, that script SHALL stop, with nothing raised and no keystroke sent, when the window is no longer open, and, when the resolution names a tab, when the window has no tab at that position, when the tab no longer passes the URL check it was found by, or when it is no longer the window's current tab. It SHALL then read the URL of the window's current tab. A check that fails in that block is reported as document-targeting, "Window-level commands act on the window they resolved", says: a document-not-found error, or the target-changed error of a check that failed after the click.

After the file dialog has appeared and before the first keystroke, and again before every later keystroke, inside each of the two waits, and before the click that confirms the dialog, the script SHALL check four things, in this order: (1) the window is still open; (2) `id of front window` is `<id>`; (3) the front window's current tab still shows the URL the first block read, compared with regard to case; (4) Safari is the frontmost application, because System Events sends keystrokes to whichever application is frontmost, whatever Safari's own window order says. When any of the four fails the script SHALL stop, send nothing further, and say that no further keystroke was sent and that a file dialog that is still open is to be dismissed before a retry; this is the script's own error, not a document-not-found error. With no targeting flag and no `--profile`, and when no window id is available, the script is the one sent before this requirement and makes none of these checks.

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

#### Scenario: native upload names the window by its id in every step

- **WHEN** user runs `safari-browser upload --native "input[type=file]" /tmp/f.txt --window 2` and window 2 has id 5822 when the command starts
- **THEN** the read that checks the target, the click on the file input and the dialog script name `window id 5822`
- **AND** no AppleScript sent after the id was read names `window 2`

##### Example: native upload by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Steps after the resolution |
| --- | --- |
| `upload --native "input" f.txt --window 2` | read and click on `document of window id 5822`; the dialog script raises `window id 5822` |
| `upload --native "input" f.txt --url work.example/a2` | one AppleScript checks the URL of `tab 2 of window id 5822` and makes it current; read and click in tab 2 of window id 5822 while it is the current tab; the dialog script checks that tab again (it is there, it passes the URL check, it is current), reads the page's URL, then raises `window id 5822`; it makes no tab current |
| `upload --native "input" f.txt --url work.example/a1` | one AppleScript checks the URL of `tab 1 of window id 5822`, and no tab is made current; read and click in tab 1 while it is the current tab |
| `upload --native "input" f.txt --url work.example/a2`, when tab 1 is made current again before the read | the upload stops with a target-changed error that says the tab had been made current; the file input is not clicked and no dialog script runs |
| `upload --native "input" f.txt --url work.example/a2`, when tab 2 shows another URL before the read | the upload stops at the read with that target-changed error; the file input is not clicked |
| `upload --native "input" f.txt --url work.example/a2`, when tab 1 is made current again between the read and the click | the click's own check stops the upload with that target-changed error, after the keyboard warning; no dialog script runs |
| the dialog script of that command, when its first block finds tab 2 showing another URL, not current, gone, or the window gone | it ends with error number 9001, 9001, 9003, 9002; nothing is raised |
| `upload --native "input" f.txt --window 2`, when the id of window 2 cannot be read | `window 2` throughout; the dialog script sent before this requirement |
| `upload --native "input" f.txt` | unchanged: `window 1` |

##### Example: front window check before every keystroke

In the dialog script for window id 5822, every `keystroke` line and the click that confirms the dialog is preceded, after the previous keystroke, by a call of the owner check, which fails when window id 5822 is gone, when `id of front window` is not 5822, when the front window's current tab no longer shows the URL the script read before it raised the window, or when Safari is not the frontmost application. The script for no targeting flag contains no such call and is the text sent before this requirement.

| Dialog script for | Calls of the front-window check | Position of the first call |
| --- | --- | --- |
| window id 5822 | seven: one before each of the three keystrokes, one inside each of the two waits, one before the confirming click, one after the file dialog appeared | after the wait for the file dialog (which contains none), before the first `keystroke` |
| `window 1` (no targeting flag) | none | (none) |

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
