## MODIFIED Requirements

### Requirement: Screenshot command accepts full TargetOptions

The `screenshot` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags. When targeting flags are supplied, the system SHALL resolve the target through the native path resolver, after `--window <n>` was resolved to the window's id at command start (document-targeting, "Window number resolved to its id at command start"). The bounds and the title the command uses to find that window among the Accessibility windows SHALL be read in one AppleScript that names the window `window id <id>` (document-targeting, "Window-level commands act on the window they resolved"). When the window is no longer open the command SHALL fail with a document-not-found error and capture nothing. No AppleScript of the command SHALL raise a window or make a tab current. The page steps of `--full` and `--element` (the size read, the scroll and its restore, the element-bounds read) SHALL run in the document that resolution fixed, as document-targeting, "Window-level commands act on the window they resolved", requires: `document of window id <id>` for a window target, and for a tab target that tab of `window id <id>`, each step only while the tab is still the window's current tab. They SHALL NOT resolve the flags a second time. `--profile` alone, `--url-exact`, `--url-endswith` and `--url-regex` are not counted as a target by this command (safari-browser#233): it then resolves no window and captures Safari's front window, and its page steps read and scroll that same front window, without resolving those flags. When the window is no longer open at a page step, or the tab the target named is gone from it, the step SHALL fail with the document-not-found error of the resolved target; the error about the current tab is given only for a tab that is still there and is no longer its window's current tab. The subsequent capture behavior depends on whether the system has Accessibility permission, per the Hidden window capture requirement below.

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

##### Example: page steps by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | What happens after the window was found | The page steps |
| --- | --- | --- |
| `screenshot --full --window 2 out.png` | window 3 is raised to the front, so window id 5822 is now window 3 | run in `document of window id 5822`; the windows are not enumerated; no step names a window by its position |
| `screenshot --full --url work.example/a1 out.png` | nothing | run in tab 1 of `window id 5822`, each checking that tab 1 is still that window's current tab; the URL is not matched a second time |
| `screenshot --full --url work.example/a1 out.png` | tab 2 of window id 5822 becomes current, and window 3 now shows `https://work.example/a1` | fail with an error that names `tab 1 of window id 5822`; nothing runs in window 3 |
| `screenshot --full --window 2 out.png` | window id 5822 closes | fail with a document-not-found error whose pattern is `window 2 (window id 5822 at command start)` |
| `screenshot --full --url work.example/a1 out.png` | window id 5822 closes | fail with a document-not-found error whose pattern begins `window id 5822 tab 1 (matched: `; not the error about the current tab |
| `screenshot --full --url work.example/b1 out.png` | window id 6933 has no tab any more | fail with a document-not-found error whose pattern begins `window id 6933 tab 1` |
| `screenshot --full --url work.example --first-match out.png` (three tabs match) | nothing | run in tab 1 of `window id 5822`, the tab the one resolution chose; the URL is not resolved a second time |
| `screenshot --full --profile Work out.png`, or with only `--url-exact`, `--url-endswith` or `--url-regex` | nothing | run in Safari's front window, the window that is captured; no AppleScript is sent to resolve the flags |
| `screenshot --full out.png` | nothing | as before this requirement: the front window |
| `screenshot --full --window 2 out.png`, when the id of window 2 cannot be read | nothing | as before this requirement: `window 2` |
