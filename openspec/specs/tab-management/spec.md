# tab-management Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: List all tabs

The system SHALL list the open tabs of the target Safari window, printing each tab's index, title, and URL to stdout. The default target SHALL be the front window. When `--window <n>` is provided, the system SHALL list the tabs of window `n` instead. When `--window-id <id>` is provided, the system SHALL list the tabs of the window with that id, and SHALL fail with a document-not-found error when it does not exist or does not belong to `--profile`. When the window that `--window`, `--window-id` or `--profile` selected is not open, or is found to have closed before its tabs were read, the system SHALL fail with a document-not-found error, whether or not another window is still open, and SHALL NOT print an empty list for it (#362). The system looks for a closed window in two cases only: reading its tabs fails with an object-not-found error (-1719 or -1728), or the read finds no tabs; in either case it lists the windows again, and the window is found to have closed when it is not among them. A read that fails with any other error (a timeout, or a message without an error number) SHALL be reported as that error, because it is no evidence that the window closed, even if it did. When listing the windows again fails after a read that failed with object-not-found, the read's error SHALL be reported as it is, not the listing's; after a read that found no tabs there is no read error, and the listing's error is reported. A cancellation is reported as a cancellation. When the system had resolved the window to an id, the error SHALL name that id and the flags given; a `--window <n>` for which no id could be read (no window `n` is open) gets the ordinary miss for window `n`. Without a target flag, Safari having no window is not an error (scenario "No tabs open"). Other targeting flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) SHALL be rejected because "listing tabs" only makes sense at window granularity.

#### Scenario: List tabs of front window

- **WHEN** user runs `safari-browser tabs` with no target flag
- **THEN** stdout contains a list of tabs of the front window with format `<index>\t<title>\t<url>` per line

#### Scenario: List tabs of specific window

- **WHEN** user runs `safari-browser tabs --window 2`
- **AND** window 2 has three tabs
- **THEN** stdout contains exactly three lines, listing the tabs of window 2
- **AND** SHALL NOT include any tabs from window 1

#### Scenario: No tabs open

- **WHEN** user runs `safari-browser tabs` and Safari has no windows
- **THEN** stdout is empty and the CLI exits with zero status

#### Scenario: the selected window closes during the command

- **WHEN** user runs `safari-browser tabs --profile Work` (or `tabs --window 2`)
- **AND** the window it selected, whose id is 4711, closes before its tabs are read
- **THEN** the command fails with a document-not-found error naming `window id 4711` and the flags given, whether that window was the last one open or another window is still open
- **AND** it does not print an empty list or exit with zero status

#### Scenario: a read that times out is not a closed window

- **WHEN** user runs `safari-browser tabs --window-id 4711` (or `tabs --window 2`)
- **AND** reading the window's tabs times out
- **THEN** the command fails with the timeout, not with a document-not-found error, whether or not the window closed

#### Scenario: tabs rejects document-level targeting

- **WHEN** user runs `safari-browser tabs --url plaud`
- **THEN** the system SHALL reject the invocation with a validation error explaining that `tabs` only accepts `--window` or `--window-id`

#### Scenario: List tabs of a window by id

- **WHEN** user runs `safari-browser tabs --window-id 4711`
- **THEN** stdout lists the tabs of the window whose id is 4711

---
### Requirement: Switch to tab by index

The system SHALL switch the target Safari window's current tab to the tab at the given index. The default target SHALL be the front window. When `--window <n>` is provided, the system SHALL operate on window `n`. When `--window-id <id>` is provided, the system SHALL operate on `window id <id>`, after checking that the window exists (and belongs to `--profile`, when given), and SHALL fail with a document-not-found error otherwise. With `--profile` and no window flag, the system SHALL operate on the profile's window by the id the enumeration read. Flags that name a tab (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`) SHALL be rejected because the tab-switch operation changes UI state inside a window.

#### Scenario: Switch to valid tab in front window

- **WHEN** user runs `safari-browser tab 2`
- **THEN** Safari's front window switches to the tab at index 2

#### Scenario: Switch to tab in specific window

- **WHEN** user runs `safari-browser tab --window 2 3`
- **THEN** window 2's current tab becomes the tab at index 3
- **AND** window 1's current tab SHALL remain unchanged

#### Scenario: Invalid tab index

- **WHEN** user runs `safari-browser tab 99` and the target window has fewer than 99 tabs
- **THEN** the CLI exits with non-zero status and stderr contains an error message

#### Scenario: Switch to tab in a window by id

- **WHEN** user runs `safari-browser tab 3 --window-id 4711`
- **THEN** the current tab of window 4711 becomes its tab 3, addressed as `window id 4711`
- **AND** no other window is changed

---
### Requirement: Open new empty tab

The system SHALL open a new empty tab in the target Safari window. The default target SHALL be the front window; `--window <n>` overrides it, and its id SHALL be read before Safari is activated. `--window-id <id>` SHALL create the tab in `window id <id>` without activating Safari, after checking that the window exists (and belongs to `--profile`, when given); the new tab SHALL still become that window's current tab. With `--profile` and no window flag, the tab SHALL be created in the profile's window by the id the enumeration read. Flags that name a tab SHALL be rejected for this operation.

#### Scenario: New tab in front window

- **WHEN** user runs `safari-browser tab new`
- **THEN** a new tab is created in the front window and becomes the current tab

#### Scenario: New tab in specific window

- **WHEN** user runs `safari-browser tab --window 2 new`
- **THEN** a new tab is created in window 2 and becomes its current tab

#### Scenario: New tab in a window by id

- **WHEN** user runs `safari-browser tab new --window-id 4711`
- **THEN** a new tab is created in window 4711 and becomes its current tab
- **AND** Safari is not activated
