## MODIFIED Requirements

### Requirement: PDF export command accepts full TargetOptions

The `pdf` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags in addition to the existing `--allow-hid` requirement. When targeting flags are supplied, the system SHALL resolve the target through the native path resolver, after `--window <n>` was resolved to the window's id at command start (document-targeting, "Window number resolved to its id at command start"), and SHALL then run one export script that names the window `window id <id>` (document-targeting, "Window-level commands act on the window they resolved"). In its first Safari block that script SHALL, in this order: fail with no menu action sent when the window is no longer open; when the target is a background tab, make it the window's current tab, after the URL check when the tab was found by its URL; read the URL of the window's current tab; raise the window; activate Safari. No separate AppleScript SHALL switch the tab. The checks the script makes before each later step compare the id of Safari's front window with `<id>` and the URL of its current tab with the URL read, and stop the export when either differs.

The `pdf` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time.

#### Scenario: pdf --url resolves to target window

- **WHEN** Safari has two windows, one showing `https://docs.example.com/`
- **AND** user runs `safari-browser pdf --url docs --allow-hid /tmp/docs.pdf`
- **THEN** the system SHALL resolve `--url docs` to the docs window index
- **AND** SHALL raise that window
- **AND** SHALL dispatch the PDF file-dialog keystroke sequence against that window

#### Scenario: pdf --document resolves via document collection

- **WHEN** Safari has three documents across two windows
- **AND** user runs `safari-browser pdf --document 3 --allow-hid /tmp/third.pdf`
- **THEN** the system SHALL identify which window owns the third document
- **AND** SHALL raise that window and dispatch the PDF dialog

#### Scenario: pdf --url with no match

- **WHEN** Safari has no window whose URL contains `xyz`
- **AND** user runs `safari-browser pdf --url xyz --allow-hid /tmp/out.pdf`
- **THEN** the system SHALL throw `documentNotFound` before dispatching any keystroke

#### Scenario: pdf names the window by its id from the first step of the export script

- **WHEN** user runs `safari-browser pdf --allow-hid --window 2 /tmp/out.pdf` and window 2 has id 5822 when the command starts
- **THEN** the export script checks that `window id 5822` exists, reads the URL of `current tab of window id 5822`, and raises `window id 5822`
- **AND** the script does not name `window 2`

##### Example: export script by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | First Safari block of the export script |
| --- | --- |
| `pdf --allow-hid --window 2 out.pdf` | the existence check on `window id 5822`; the URL of `current tab of window id 5822`; `set index of window id 5822 to 1`; `activate`; no `set current tab` |
| `pdf --allow-hid --url work.example/a2 out.pdf` | the existence check; the URL check on `tab 2 of window id 5822`; `set current tab of window id 5822 to` that tab; then the URL read, the raise and `activate`, in that order |
| `pdf --allow-hid --window-id 5822 --tab-in-window 2 out.pdf` | as the row above, without the URL check |
| `pdf --allow-hid out.pdf` | unchanged: `set pdfWindowID to id of window 1` |
| `pdf --allow-hid --window 2 out.pdf`, when the script reports that window id 5822 is gone | the command fails with a document-not-found error whose pattern is `window 2 (window id 5822 at command start)` |
