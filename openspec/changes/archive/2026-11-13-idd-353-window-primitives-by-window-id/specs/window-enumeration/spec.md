## MODIFIED Requirements

### Requirement: The enumeration decoder fails closed

The system SHALL decode the enumeration text into windows and tabs only when every check below holds, and SHALL otherwise fail the command with `SafariBrowserError.windowEnumerationCorrupt(reason:kind:)` (`kind` defaults to the shape problem), without returning any window. The checks: the text parses as AppleScript source form and is a list (an empty text is not a list); every item is a list of six elements; each item's first element is an integer equal to its 1-based position; the window id is an integer or `missing value`; the window name is text or `missing value`; the current-tab index is an integer; the URL and name lists are lists of equal length whose items are text or `missing value`; a window with no tabs has current-tab index 0 and a window with tabs has a current-tab index of at least 1; no two windows report the same window id. The script produces two windows with one id only while Safari's windows change under it (a window opened or raised mid-enumeration is read at two positions); that state SHALL fail the command too, with an error that says the windows changed while they were read and to run the command again. This check catches a window read at two positions; it does not catch a window raised between the read of its own id and the reads of its tabs, which pairs that id with the tabs of the window then at its position (the reads keep the order they had before this requirement). A window id that is a real number (osascript writes `3.5` or `5.36870912E+8`, the daemon conversion `«class doub»`; an id of 2^29 or more arrives as one) SHALL fail with an error that names the AppleScript integer limit as the likely cause and SHALL NOT suggest that running the command again helps; this applies to real numbers only, and SHALL NOT be extended to other kinds by resemblance. A window id that is any other non-integer kind (a boolean, raw data, a class, text or a list) is a shape problem. Every rejection other than these two SHALL say the list could not be read, to run the command again, and to report it if it keeps failing. A window with tabs whose current-tab index is above its tab count (a tab opened and made current between the two reads) SHALL be listed with all its tabs and no tab current; its current-tab index SHALL NOT be taken to be tab 1. `missing value` SHALL decode to an empty URL, title or window name and to no window id. The error's reason SHALL name only positions, counts and kinds of value, and SHALL NOT contain any text from the enumeration's strings or atoms.

#### Scenario: an empty text is not "no windows"

- **WHEN** the enumeration text is empty
- **THEN** the command fails with `windowEnumerationCorrupt` instead of reporting that Safari has no windows

#### Scenario: unequal URL and name lists

- **WHEN** a window's URL list has 3 items and its name list has 4
- **THEN** the command fails with `windowEnumerationCorrupt` whose reason names the window's position and the two counts and contains none of the names

##### Example: rejected shapes

| Enumeration text | Rejected because |
| --- | --- |
| `` | empty text |
| `{{1, 7, "w", 1, {"u"}, {"t"}, 9}}` | seven elements |
| `{{2, 7, "w", 1, {"u"}, {"t"}}}` | first window numbered 2 |
| `{{1, 3.5, "w", 1, {"u"}, {"t"}}}` | window id is a real number (the 2^29 advice, no rerun) |
| `{{1, true, "w", 1, {"u"}, {"t"}}}` | window id is a boolean (shape advice) |
| `{{1, 7, "w", 1, {}, {}}}` | no tabs but a current tab |
| `{{1, 7, "w", 1, {"u"}, {"t"}}, {2, 7, "x", 1, {"v"}, {"s"}}}` | duplicate window id |

#### Scenario: a tab opened during the enumeration

- **WHEN** a window's record has two tabs and current-tab index 3
- **THEN** the window is listed with both tabs, neither marked current
- **AND** `pdf` and `upload --native`, naming tab 1 with `--window-id` and `--tab-in-window 1`, switch to tab 1 instead of assuming it is current
- **AND** `close` naming that tab closes tab 1 by its position in the window and makes no tab current
- **AND** `screenshot` naming that tab refuses with `backgroundTabNotCapturable` (v2.9.0 captured the window, which showed the newly opened tab)
- **AND** document-scoped JavaScript commands, which do not read the window's current-tab index, behave as before

#### Scenario: a current-tab index below 1 on a window with tabs

- **WHEN** a window's record has two tabs and current-tab index 0
- **THEN** the command fails with `windowEnumerationCorrupt`

#### Scenario: the advice follows the reason

- **WHEN** the enumeration is rejected because two windows report one id
- **THEN** the error says the windows changed while they were read and to run the command again, without asking for a report
- **AND** when it is rejected because a window id is a real, the error names the AppleScript integer limit and does not suggest running the command again

##### Example: a tab opened during the enumeration, by command

Window id 5822 is listed with two tabs and current-tab index 3. Each command names tab 1 with `--window-id 5822 --tab-in-window 1`.

| Command | What it does with tab 1 |
| --- | --- |
| `pdf --allow-hid out.pdf` | the export script makes `tab 1 of window id 5822` current before it raises the window |
| `upload --native "input" f.txt` | one AppleScript makes `tab 1 of window id 5822` current |
| `close` | one AppleScript closes `tab 1 of window id 5822`; no tab is made current |
| `screenshot out.png` | refuses with `backgroundTabNotCapturable` |
