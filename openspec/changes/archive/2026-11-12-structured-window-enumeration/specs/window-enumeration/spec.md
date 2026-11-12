## Purpose

Defines how the system enumerates Safari's windows and tabs in one AppleScript round trip, the structured form that enumeration returns on both execution paths, and how its output is decoded. Every targeting command, `documents`, `tabs`, `tab` and `open` act on this enumeration, so page-controlled text (tab titles, window names, URLs) must never be able to add, remove or alter a row.

## ADDED Requirements

### Requirement: The window enumeration returns one structured record per window

The window enumeration script SHALL return an AppleScript list with one item per Safari window, in Safari's window order. Each item SHALL be a list of exactly six elements: the window's 1-based index, its window id (an integer, or `missing value` when it cannot be read), its window name (text, or `missing value`), the index of its current tab, the list of its tabs' URLs, and the list of its tabs' names. A window with no tabs SHALL be emitted with the same six elements, current-tab index 0 and two empty lists, so the enumeration stays dense. When Safari has no windows the script SHALL return an empty list. Tab titles, window names and URLs SHALL appear only as text values inside these lists; the script SHALL NOT join them into text with separator characters, and SHALL NOT read, replace or test their characters. The script SHALL read each window's tab URLs and names with whole-window reads, re-read the URLs and compare the two reads case-sensitively, fall back to per-tab reads only when no stable whole-window read was obtained, and SHALL NOT send more Apple events than this.

#### Scenario: a window with three tabs

- **WHEN** Safari has one window with id 4711, named `個人 — Example`, whose second of three tabs is current
- **THEN** the script returns `{{1, 4711, "個人 — Example", 2, {url1, url2, url3}, {name1, name2, name3}}}`

#### Scenario: a window with no tabs keeps its slot

- **WHEN** Safari's second of three windows has no tabs
- **THEN** the second item is `{2, id, name, 0, {}, {}}` and the third item's first element is 3

#### Scenario: no windows

- **WHEN** Safari has no windows
- **THEN** the script returns `{}`

### Requirement: Both execution paths produce the enumeration in AppleScript source form

The system SHALL obtain the enumeration as AppleScript source form text: strings in double quotes with `"` written as `\"` and `\` written as `\\` and every other character written as itself, lists in braces with items separated by `, `, integers in decimal, and `missing value`. The stateless path SHALL run the script with `osascript -s s`. The daemon path SHALL convert the result descriptor into the same text, for `applescript.execute` requests that carry `"resultForm": "sourceForm"` and for the in-process runner used by `exec.runScript`. For the same result made of lists, text, AppleScript integers and `missing value` (the kinds the enumeration returns), the two paths SHALL produce byte-identical text, including the treatment of unpaired UTF-16 surrogates: a string is split at each `"` and `\`, and each part is cut at its first unpaired surrogate, as `osascript -s s` does. Other kinds of value (reals, booleans, raw `utf8` or `TEXT` data) SHALL decode to a value the enumeration decoder rejects on both paths; raw data of integer type is the one kind the daemon cannot tell from an integer. An `applescript.execute` request without `resultForm` SHALL keep returning the result's string value; a `resultForm` that is present but is not the string `"sourceForm"` SHALL be answered with `status: error`, `errorKind: badRequest`. The daemon path SHALL be used only with a daemon whose handshake announces the `"sourceForm"` capability (requirement "Client requires a capability before sending a request that needs it" of `persistent-daemon`); a daemon from before this change, which can pass the version check (#320), SHALL receive no request, and the system SHALL print one `[daemon fallback: …]` line naming `safari-browser daemon stop` and then `safari-browser daemon start` and run the script on the stateless path. An empty answer from a daemon that announced the capability SHALL NOT be rerun; it reaches the decoder, which rejects it.

#### Scenario: a title with separators, quotes and line breaks

- **WHEN** a script returns a list holding a string with U+001D, U+001E, `"`, `\`, CR, LF and a combining mark after a quote
- **THEN** the text from `osascript -s s` and the text converted from the `NSAppleScript` descriptor are byte-identical
- **AND** decoding either text yields the original string

#### Scenario: an unpaired surrogate

- **WHEN** a script returns the string `A`, U+D83D, `B`
- **THEN** both paths produce `"A"`

##### Example: unpaired surrogates

| String (UTF-16) | Source form on both paths |
| --- | --- |
| `0041 D83D 0042` | `"A"` |
| `0022 D83D 0022` | `"\"\""` |
| `0041 D83D DE00 0042 D800` | `"A😀B"` |
| `DC00 0042` | `""` |

#### Scenario: a daemon request without a result form

- **WHEN** a client sends `applescript.execute` without `resultForm` for a script that returns text
- **THEN** the response's output is the text, unquoted, as before

#### Scenario: a daemon from before this change

- **WHEN** daemon mode is on and the daemon's handshake does not announce `"sourceForm"`
- **THEN** no request is sent to it, the system prints one `[daemon fallback: …]` line naming `safari-browser daemon stop` and `safari-browser daemon start`, runs the enumeration with `osascript -s s`, and decodes that result

#### Scenario: a result form that is not a string

- **WHEN** a client sends `applescript.execute` with `"resultForm": true`
- **THEN** the response is `status: error` with `errorKind: badRequest`

### Requirement: The enumeration decoder fails closed

The system SHALL decode the enumeration text into windows and tabs only when every check below holds, and SHALL otherwise fail the command with `SafariBrowserError.windowEnumerationCorrupt(reason:kind:)` (`kind` defaults to the shape problem), without returning any window. The checks: the text parses as AppleScript source form and is a list (an empty text is not a list); every item is a list of six elements; each item's first element is an integer equal to its 1-based position; the window id is an integer or `missing value`; the window name is text or `missing value`; the current-tab index is an integer; the URL and name lists are lists of equal length whose items are text or `missing value`; a window with no tabs has current-tab index 0 and a window with tabs has a current-tab index of at least 1; no two windows report the same window id. The script produces two windows with one id only while Safari's windows change under it (a window opened or raised mid-enumeration is read at two positions); that state SHALL fail the command too, with an error that says the windows changed while they were read and to run the command again. A window id that is a real number (osascript writes `3.5` or `5.36870912E+8`, the daemon conversion `«class doub»`; an id of 2^29 or more arrives as one) SHALL fail with an error that names the AppleScript integer limit as the likely cause and SHALL NOT suggest that running the command again helps; this applies to real numbers only, and SHALL NOT be extended to other kinds by resemblance. A window id that is any other non-integer kind (a boolean, raw data, a class, text or a list) is a shape problem. Every rejection other than these two SHALL say the list could not be read, to run the command again, and to report it if it keeps failing. A window with tabs whose current-tab index is above its tab count (a tab opened and made current between the two reads) SHALL be listed with all its tabs and no tab current; its current-tab index SHALL NOT be taken to be tab 1. `missing value` SHALL decode to an empty URL, title or window name and to no window id. The error's reason SHALL name only positions, counts and kinds of value, and SHALL NOT contain any text from the enumeration's strings or atoms.

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
- **AND** a native-path command that switches tabs (`pdf`, `upload --native`, `close`) and names tab 1 with `--window-id` and `--tab-in-window 1` switches to tab 1 instead of assuming it is current
- **AND** `screenshot` naming that tab refuses with `backgroundTabNotCapturable` (v2.9.0 captured the window, which showed the newly opened tab)
- **AND** document-scoped JavaScript commands, which do not read the window's current-tab index, behave as before

#### Scenario: a current-tab index below 1 on a window with tabs

- **WHEN** a window's record has two tabs and current-tab index 0
- **THEN** the command fails with `windowEnumerationCorrupt`

#### Scenario: the advice follows the reason

- **WHEN** the enumeration is rejected because two windows report one id
- **THEN** the error says the windows changed while they were read and to run the command again, without asking for a report
- **AND** when it is rejected because a window id is a real, the error names the AppleScript integer limit and does not suggest running the command again

### Requirement: Page text cannot forge enumeration rows

The rows and window ids the system derives from the enumeration SHALL depend only on the enumeration's structure, never on the characters inside tab titles, window names or URLs. Profiles are the exception this requirement does not close: a window's profile is parsed from its window name, and a default-profile window's name is its page title, so a page title can still claim a profile (tracked in #364). `documents --json` SHALL keep its keys and row shape. The decoded title, URL and window name SHALL hold the characters Safari returned, and `--json` SHALL print them as they are, except that an unpaired UTF-16 surrogate SHALL be dropped together with the characters after it up to the next `"` or `\` in that string, identically on both execution paths (the rule of the requirement "Both execution paths produce the enumeration in AppleScript source form"). Safari cuts `name of tab` at 1000 UTF-16 units without regard to surrogate pairs, so a title ending in an emoji can arrive with an unpaired high surrogate; such a tab SHALL stay listed with its URL, and its window SHALL keep its window id.

#### Scenario: a title that holds a forged record

- **WHEN** the current tab of a window of a named profile, with three tabs, has a title holding U+001E, a record for tab 99 of window 1 with a URL on another host, and U+001E again
- **THEN** the enumeration yields exactly three tabs for that window, the decoded title holds those characters unchanged, and the window keeps its own profile and window id

#### Scenario: a title cut inside a surrogate pair

- **WHEN** a window with id 4711 has two tabs, the second of which is current and has the title `a` × 999 followed by an unpaired U+D83D (Safari's 1000-unit cut through `😀`), and the window name is `個人 — ` followed by that title
- **THEN** on either execution path the enumeration lists both tabs, the second with its URL and the title `a` × 999
- **AND** both tabs carry window id 4711 and the profile `個人`
- **AND** `documents --json` lists two rows, `--url` with the second tab's URL selects it, and `--window-id 4711 --profile 個人` selects the window

#### Scenario: text-mode output is outside this requirement

- **WHEN** `documents` prints a title in text mode (`tabs` reads its titles with its own per-tab reads, not from this enumeration)
- **THEN** this requirement makes no claim about how control characters in it are shown; escaping them is tracked in #369
