## MODIFIED Requirements

### Requirement: Screenshot command accepts full TargetOptions

The `screenshot` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags. When targeting flags are supplied, the system SHALL resolve the target through the native path resolver, after `--window <n>` was resolved to the window's id at command start (document-targeting, "Window number resolved to its id at command start"). The bounds and the title the command uses to find that window among the Accessibility windows SHALL be read in one AppleScript that names the window `window id <id>` (document-targeting, "Window-level commands act on the window they resolved"). When the window is no longer open the command SHALL fail with a document-not-found error and capture nothing. No AppleScript of the command SHALL raise a window or make a tab current. The subsequent capture behavior depends on whether the system has Accessibility permission, per the Hidden window capture requirement below.

The `screenshot` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time.

#### Scenario: screenshot --url resolves target window

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/`
- **AND** user runs `safari-browser screenshot --url plaud /tmp/plaud.png`
- **THEN** the system SHALL resolve `--url plaud` to the plaud window index
- **AND** SHALL capture that window's content
- **AND** SHALL save the PNG to `/tmp/plaud.png`

#### Scenario: screenshot --document maps to owning window

- **WHEN** Safari has three documents across two windows
- **AND** user runs `safari-browser screenshot --document 3 /tmp/third.png`
- **THEN** the system SHALL identify which window owns the third document
- **AND** SHALL capture that window's content

#### Scenario: screenshot reads the window it resolved by its id

- **WHEN** user runs `safari-browser screenshot --window 2 /tmp/shot.png` and window 2 has id 5822 when the command starts
- **THEN** the bounds and the title are read from `window id 5822` in one AppleScript
- **AND** no AppleScript sent after the id was read names `window 2`

##### Example: geometry read by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | AppleScript that reads the bounds and the title |
| --- | --- |
| `screenshot --window 2 out.png` | names `window id 5822`; contains no `window 2`, no `set index`, no `activate`, no `set current tab` |
| `screenshot --url work.example/a1 out.png` | names `window id 5822` |
| `screenshot --url work.example/a2 out.png` | none is sent: the target is a background tab and the command refuses |
| `screenshot --window 2 out.png`, when window id 5822 closes after the id was read | none succeeds: document-not-found with the pattern `window 2 (window id 5822 at command start)` |

How the window is then found among the Accessibility windows, and the capture itself, are not covered by this Example: they need Accessibility and a real Safari.
