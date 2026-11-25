## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the tabs the miss is about — every tab for an unscoped miss; for a scoped miss fewer (a miss on one window's tab lists that window's tabs, a window-level miss lists each window's current tab) — each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and, whenever it lists any URL, MUST say that `safari-browser documents` prints the URLs in full (an empty listing has no URL to say it about), so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`. A missing window named by `--window-id` is the exception: it names one window and SHALL list no tab, except that with `--profile` it SHALL list that profile's windows, a window whose enumeration record has an id by that id and one whose record has none by Safari's number, marked `(no window id)`. A `--window N` that was resolved to its window id at command start (see "Window number resolved to its id at command start") and whose window or tab is gone later in the command is item 8 below, not item 2. When the system enumerates Safari again to list what is open after a miss and that enumeration fails, the listing SHALL be one note saying that the open tabs could not be listed, naming only the kind of failure (an AppleScript error code, a timeout, a malformed list) and never the error's own text; it SHALL NOT say that no document, or no window of a profile, is open, and the hint SHALL NOT say that listed entries carry coordinates (#362).

With `--profile`, `--window N` counts only that profile's windows, while a listing shows Safari's own window numbers, so a number copied from a listing into `--window N` with `--profile` can select another window (#362). When the target carries `--profile` (for item 2, when the target carries it or its caller passes it beside the target), the listings of the following misses SHALL name each listed window's id beside Safari's own window number (`window 3 tab 1 (window id 4711): …`), and an entry from an enumeration record that carries no id SHALL say `(no window id)` instead. Their hint SHALL NOT point at `--window N` with `--profile`, and SHALL say how each kind of entry is targeted: an entry that names an id with `--window-id W`, adding `--tab-in-window M` where the entry names a tab, with or without `--profile` (for item 7, without `--profile` or with the profile its brackets name); an entry marked `(no window id)` with `--window N`, adding `--tab-in-window M` where the entry names a tab, without `--profile`. When every entry names an id the hint gives only the first way, when no entry does only the second, and when the listing has both kinds of entry it gives both, each for its kind:

1. a resolved tab whose window is no longer there when the resolver checks it again: a `.resolvedTab` or `.anchoredCurrentTab` target that re-enters the resolver (`listing(_:within:scope:)`);
2. a tab that disappeared during a command, as `runTargetedAppleScript` translates the error, when the target carries the profile or its caller passes the profile beside a target that does not. The callers that pass it are these, and only these: `get url`, `get title` and `get source`; the bridge's text read (`getCurrentText`), which passes the profile so that the bridge treats it as it treats the three readers above, although no command passes a profile to it: the `get text` command resolves its target before calling it and passes none, so `get text` itself is unchanged (see the #368 exception); the JavaScript dispatch of `doJavaScript` for a `--window N` or `--window N --tab-in-window M` target that is still a position because its window id could not be read at command start (#354); and, for every step after their resolution, the window-level commands of "Window-level commands act on the window they resolved": `close`, `pdf`, `screenshot`, and `upload` on its native paths. The miss line of this translation repeats the target as it was given to the translation: what was typed, which for `--window N --profile P` is the profile's ordinal while the entries show Safari's numbers; or, for those window-level commands, the target their resolution produced, which is `window id W`, or `window id W tab T` (followed by ` (matched: …)` for a tab found by its URL), the pattern of item 8 for a `--window N` resolved at command start, and Safari's own window number only in the cases of that requirement that keep the position. When such a command was given `--window-id W` (with or without `--tab-in-window T`) or `--profile` alone, and carries `--profile`, the miss is the `--window-id` miss of the first paragraph: its pattern ends with ` (profile: "P")` and it lists that profile's windows by id, or, when window `W` is still open and belongs to the profile but has no tab at the position named, that window's tabs, each with the window's id. A tab found by `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab` or `--document` under `--profile` is a resolved tab that carries the profile: its miss has no such suffix and lists that profile's tabs with their window ids, as item 1 does;
3. a URL target (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`) that matches no tab;
4. `--window N --tab-in-window M` whose tab number is out of range in that window;
5. `--document N` with `N` below 1, which only a direct caller of the resolver can produce: the command line rejects `--document` below 1 before any target is resolved;
6. `--document N` beyond the last tab, whose entries name windows, not tabs;
7. a target other than `--window-id` whose `--profile` matches no open window when the resolver filters the windows by profile (`pickNativeTarget`). Its listing names every open window, each with its profile in brackets, or `[(no profile)]` for a window that has none (no `--profile` selects such a window), and its id (`window 2 [Work] (window id 303): …`). Its hint says that no window of that profile is open; when some listed window has a profile, that the listed windows belong to other profiles and to check the `--profile` name against them, and when none has, that none of them has a profile and no `--profile` selects them; when some listed entry names an id, that `--window-id W` selects that window without `--profile`, or, where its brackets name a profile, with that profile (not with the `--profile` that was given, which matches no window); and that an entry without an id is targeted with `--window N` without `--profile`. When no entry names an id, the hint gives only that last way. The other misses for a profile with no open window (a `--window-id` target, the translation in item 2, a resolved tab that carries the profile, and `tabs` when the profile's last window closes during the command and its record carried an id; when the record had none, `tabs` resolves what was typed again and gets this item's listing) list only the note `(no window of profile "P" is open)`, under the last exception below.
8. a `--window N` or `--window N --tab-in-window M` target resolved to its window id at command start whose window or tab is gone later in the command (#354). Its pattern names what was typed and the id, `window N (window id W at command start)` or `window N tab M (window id W at command start)`. A tab that is gone from a window that is still open lists that window's tabs, with or without `--profile`. A window that is gone lists, when the caller passes the profile beside the target (the callers of item 2 and every command that passes `--profile` to each call), that profile's tabs, or the note `(no window of profile "P" is open)`; without the profile it lists one note, which says that the command did not move on to the window now in that position and is one of two, a closed list: (i) when a lookup that names only the window did not find it (a read of its position, or an enumeration), the note says the window is no longer open; (ii) when the failed step named the window's current tab and nothing is looked up afterwards (a target without `--tab-in-window`), the note says that the window, or its current tab, could not be found, because a window that has no tab gives that step the same answer. When the listing of a pinned miss holds only notes, its hint is one of three, a closed list, and each points at `safari-browser documents` and says the command did not move on to the window now in that position: (a) the listing says the current tab could not be read (the anchor of `js`, `wait` or `save-pdf` got no answer): the window could not be read just now, and nothing says it closed; (b) the pattern names a tab: the window is no longer open, or no longer has that tab; (c) otherwise: the window is no longer open, or its current tab could not be found (the note above the hint says which of the two is known). A listing whose follow-up enumeration failed gets the hint of the scenario "the enumeration after a miss fails" instead, whatever the pattern.

This list is closed: no other listing is promised to name window ids, by analogy or otherwise. These listings under `--profile` do not, each for its own reason:

- the window-out-of-range misses of `--window N` and `--window N --tab-in-window M` label each window by the profile's own ordinal, adding `(Safari window N)` where the two differ, and `--window N` takes that ordinal correctly under `--profile`;
- a `--window-id` miss under `--profile` (whose listing `tabs` also reports when the window it read closed) and `--window-id W --tab-in-window M` with a tab out of range name each window that has an id by that id alone (`window id 303: …`), with no Safari number beside it. A record without an id is named by Safari's number instead (`window 3 (no window id): …`), and the hint treats these entries as it treats the entries of the list above, with and without an id;
- the translation for callers that hand it a positional target without the profile, which are not yet scoped; they list every profile's tabs with Safari's numbers. Since #353 the native `upload` paths (the tab script, the read that checks the target, and the click) and the window read of `screenshot` are not among them when they name the window by its id: they pass the profile, as item 2 says. When no id is available for the window (the second case of "Window-level commands act on the window they resolved" that keeps the position), the native `upload` read and click and `screenshot`'s two positional reads still hand the translation Safari's window number without the profile. The follow-up reads (length, chunks, cleanup) of a large JavaScript result (`doJavaScriptLarge`, which `snapshot` uses) receive the typed `--window N` or `--window N --tab-in-window M` target without the profile, and also address Safari's window N rather than the profile's, only when the window id could not be read at command start; when it was read (#354), they receive that id, which names the profile's window. The bridge's dropping of the profile on those reads stays tracked in #372;
- `ambiguousWindowMatch` is a different error, and it is outside the scope of #362 by the maintainer's decision. Under `--profile` its candidates still show Safari's numbers beside advice about `--window N`, which is tracked in #370;
- the translation in item 2 for a target that `--profile` resolved to a position because its enumeration record carries no window id, when the target reaches the translation without the profile (as through `get text`): it lists every profile's tabs with Safari's numbers and no ids (#368);
- the listing that the `--first-match` fallback gives when nothing matches names every window, not only the profile's, and it is reached only after the profile's windows matched more than once, so it is not reached;
- a listing that is empty or made only of notes, such as `(no window of profile "P" is open)`, names no window and so no id. The hint of such a positional miss cannot name ids either: it says that no tab is listed, to read coordinates from `safari-browser documents` and to use `--window N --tab-in-window M`, warning that under `--profile` N counts only that profile's windows.

Known limitation, left for a follow-up: when the windows of the profile have no tabs, the listings of items 1 and 3 are empty, and the listing of item 4 is empty whenever the window it names has no tabs; an empty listing renders as `(no Safari documents are currently open)`. In the same situation the translation in item 2 lists `(no window of profile "P" is open)`, although a window of the profile is open. Both describe what the enumeration of tabs found, not what is open.

#### Scenario: URL substring with no matching document

- **WHEN** Safari has documents `[https://web.plaud.ai/, https://platform.claude.com/]`
- **AND** user runs `safari-browser get --url xyz url`
- **THEN** the system SHALL throw `documentNotFound` with `pattern: "xyz"` and `availableDocuments` listing both URLs
- **AND** the error description SHALL contain both `https://web.plaud.ai/` and `https://platform.claude.com/`

#### Scenario: Window index out of range

- **WHEN** Safari has one window
- **AND** user runs `safari-browser get --window 5 url`
- **THEN** the system SHALL throw `documentNotFound` identifying the requested window index
- **AND** the error description SHALL list available windows

#### Scenario: a miss under a profile names window ids

- **WHEN** the windows of the profile `Work` are Safari windows 2 and 3, with ids 303 and 404
- **AND** user runs `safari-browser get --url xyz --profile Work url` and no tab of `Work` matches
- **THEN** the listing names `window 2 tab 1 (window id 303): …` and the other tabs of `Work` the same way, and no tab of another profile
- **AND** the hint points at `--window-id W --tab-in-window M`
- **AND** `--window-id 303 --tab-in-window 1 --profile Work` selects the tab the first entry names

#### Scenario: a profile with no open window lists the others with their ids

- **WHEN** the windows of the profile `Work` are Safari windows 2 and 3, with ids 303 and 404, and no window of the profile `Wrok` is open
- **AND** user runs `safari-browser tabs --profile Wrok`
- **THEN** the listing names every open window with its profile and id, as in `window 2 [Work] (window id 303): …`
- **AND** the hint says that no window of that profile is open and points at `--window-id W`, not at refining a `--url` substring and not at `--window N`
- **AND** `--window-id 303`, with or without `--profile Work`, selects Safari window 2

#### Scenario: the enumeration after a miss fails

- **WHEN** a command's target was found, is gone when the command reads it, and the enumeration that would list the open tabs fails with AppleScript error -1712
- **THEN** the error lists one note saying the open tabs could not be listed, with `AppleScript error -1712`
- **AND** the error does not say that no document is open, nor that no window of a profile is open, and contains no text of the AppleScript error message

#### Scenario: the enumeration after a miss comes back malformed

- **WHEN** a command's target is not found and the enumeration that would list the open tabs fails with `windowEnumerationCorrupt`
- **THEN** the error lists one note saying the open tabs could not be listed, naming a malformed list
- **AND** the note contains no text of the corruption reason

#### Scenario: a pinned window that closes under a profile lists the profile's tabs by id

- **WHEN** the windows of the profile `Work` are Safari windows 2 and 3, with ids 303 and 404, and user runs `safari-browser get url --window 2 --profile Work`
- **AND** window 404 closes after the command read its id and before it reads the URL
- **THEN** the pattern is `window 2 (window id 404 at command start)`, the listing is `window 2 tab 1 (window id 303): …` and the other tabs of `Work`, and no tab of another profile
- **AND** the hint points at `--window-id W`, not at `--window N`

##### Example: misses of window-level commands under a profile

Safari's windows, front to back: window 1 has id 4711, belongs to the profile `Home` and has tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Windows 2 and 3 belong to the profile `Work`. Tab 1 is the current tab of each window.

| Miss worded for | State when it is worded | Pattern | Listing |
| --- | --- | --- | --- |
| `window id 5822`, with `--profile Work` | window id 5822 is closed | `window id 5822 (profile: "Work")` | `window id 6933: https://work.example/b1` |
| `window id 5822 tab 2`, with `--profile Work` | window id 5822 is closed | `window id 5822 tab 2 (profile: "Work")` | `window id 6933: https://work.example/b1` |
| `window id 5822 tab 2`, with `--profile Work` | window id 5822 is open with one tab | `window id 5822 tab 2 (profile: "Work")` | that window's one tab, `… (window id 5822): https://work.example/a1` |
| `window id 5822`, with `--profile Work` | only window 1 is open | `window id 5822 (profile: "Work")` | `(no window of profile "Work" is open)` |
| `window id 4711 tab 9`, with `--profile Work` | all three windows are open | `window id 4711 tab 9 (profile: "Work")` | the two windows of `Work`, by id; no tab of `Home` |
| `window id 5822`, without `--profile` | window id 5822 is closed | `window id 5822` | one note; no AppleScript is sent to list anything |
| `close --window-id 5822 --profile Work` | window id 5822 closes after the resolution | `window id 5822 (profile: "Work")` | `window id 6933: https://work.example/b1`; nothing is closed |
| `close --profile Work` | window id 5822 closes after the resolution | `window id 5822 (profile: "Work")` | `window id 6933: https://work.example/b1`; nothing is closed |
| `close --document 2 --profile Work` (tab 2 of window id 5822) | window id 5822 closes after the resolution | `window id 5822 tab 2`, with no suffix | `window 2 tab 1 (window id 6933): https://work.example/b1`; nothing is closed |

### Requirement: Window-level commands act on the window they resolved

`close`, `pdf`, `screenshot`, `upload` on its native paths (`--native`, `--allow-hid`, or the default when Accessibility is granted), and `open` when it reveals an existing tab SHALL, once their target is resolved, name the target window as `window id <id>` in every AppleScript they send afterwards, where `<id>` is the id the resolution read for that window. After the resolution no AppleScript of the command SHALL name the target window by its position (`window <n>`), and none SHALL reach the target window through Safari's `front window`, except inside a check that stops the command unless `id of front window` is `<id>`. An enumeration that lists every window does not name the target, and neither does the new tab `open` creates in the front window when it leaves a window on another Space alone. The steps a System Events block performs on the file sheet of the front window are outside this sentence; that check is what guards them (see file-upload and pdf-export).

Three cases keep the position, and the list is closed:

1. `close`, `pdf`, `screenshot` or `upload` was given no targeting flag and no `--profile`. The command acts on the front window with the scripts it sent before this requirement (safari-browser#287).
2. No id is available for the window: `--window <n>` stayed a position at command start (the note of "Window number resolved to its id at command start" was written), or the enumeration record of the resolved window carries no window id. The command sends the same scripts, with the same checks, with `window <n>` in place of `window id <id>`, except for these two, a closed list: the native `upload` paths read and click in the tab or the window named by its position without checking that a named tab is still the window's current tab, and their dialog script is the one sent before this requirement; `screenshot` makes the two reads it made before this requirement (an existence probe, then the bounds and the title), and its page steps resolve the command's flags again.
3. `screenshot` was given `--profile` alone, `--url-exact`, `--url-endswith` or `--url-regex`, with none of `--url`, `--window`, `--window-id`, `--tab` and `--document`. `screenshot` does not count these as a target: it resolves no window and captures Safari's front window, as it did before this requirement (safari-browser#233). Its page steps, which before this requirement resolved those flags and so could run in another window than the one captured, run in that same front window.

A window id the user typed with `--window-id` is never a position: the command names `window id <id>` whatever the enumeration record of that window carries.

When the resolution names one tab (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab`, `--document`, `--tab-in-window`, or the URL `open` was asked to reveal), the command SHALL name it `tab <t> of window id <id>`. `<t>` is a position inside that window (safari-browser#188).

When the tab was found by its URL (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, or the URL `open` was asked to reveal), the first AppleScript that acts on it (closes it, makes it the current tab, or raises its window) SHALL check the tab's URL before it acts, in that same AppleScript, and SHALL act only when the check holds. The check is case-sensitive. For `--url`, `--url-exact` and `--url-endswith` it holds when the URL still satisfies the flag. For `--url-regex` it holds when the URL equals the URL the resolution read for that tab, or, when that URL is longer than 2,000 characters, starts with its first 2,000 characters. For `open` it holds when the URL equals the requested URL. When the check fails the command SHALL fail with a target-changed error and SHALL NOT resolve the target again. The error SHALL say what the command had done by then, one of three, a closed list: (1) before any action of the command, that nothing was done to the tab; (2) in the native `upload` paths after their tab script, at the read that checks the target or at the click, that the command had already made the tab current when it was not, and that the file input was not clicked; (3) in the native `upload` paths after the click on the file input, in the first Safari block of the dialog script, that no window was raised and no keystroke was sent, and that the click may have opened a file dialog, to be dismissed before a retry. A tab named by its position (`--tab`, `--document`, `--tab-in-window`) is not checked. `pdf` and the native `upload` paths run the check on every tab the resolution names, whether or not it was the current tab of its window when it was resolved.

A step that needs a named tab to be its window's current tab SHALL check that in the same AppleScript and SHALL NOT act when it is not: the read, the click and the dialog script of the native `upload` paths, which then fail with the target-changed error above, and the page steps of `screenshot`, which fail with an error that names the tab and says it is no longer the current tab of its window. That error is only for a tab that is still there: a page step whose window is no longer open, or whose tab is gone from it, fails with the document-not-found error below.

The page steps of `screenshot --full` and `screenshot --element` (the size read, the scroll and its restore, the element-bounds read) SHALL run in the document the resolution fixed: `document of window id <id>` when the target names a window, and `tab <t> of window id <id>` when it names a tab. They SHALL NOT resolve the command's flags a second time.

When the target window is no longer open at a step that names it by its id, the command SHALL fail with a document-not-found error before that step acts: no tab is closed, no tab is made current, no window is raised, no keystroke or click is sent, and nothing is captured. The command SHALL NOT act on the window now in that position, on the front window, or on any other window. For a window whose id was read from `--window <n>` at command start, the error's pattern SHALL be the one "Window number resolved to its id at command start" defines. The same holds when the window is open but has no tab at the position the resolution named: the command SHALL fail with a document-not-found error before any tab is made current, any window is raised, or any keystroke is sent.

One kind of step is outside the paragraph above: once `pdf`'s save sheet or `upload`'s file dialog is on screen, the owner check of that script (pdf-export, file-upload) stops it with the script's own error, which says that no further keystroke was sent. That error is not a document-not-found error.

A script reports that its window is gone, that a named tab is gone, or that a check failed, by ending with an AppleScript error number of its own: 9002, 9003 and 9001. The command SHALL recognise these by the number at the end of the error, never by the error's text: the scripts include System Events blocks, whose error text can carry a window's name, which is a page's title.

The Examples below check the AppleScript text each command sends and the order it is sent in. What a keystroke, a raise or a capture does on a real Safari is outside their reach.

#### Scenario: A window raised after the resolution does not redirect the command

- **WHEN** user runs `safari-browser close --window 2`, window 2 has id 5822 when the command starts, and another window is raised to position 2 before the tab is closed
- **THEN** the current tab of `window id 5822` is closed
- **AND** no AppleScript sent after the id was read names `window 2`

#### Scenario: The target window closes before the command acts

- **WHEN** user runs `safari-browser close --window 2`, window 2 has id 5822 when the command starts, and that window closes before the tab is closed
- **THEN** the command fails with a document-not-found error whose pattern begins with `window 2 (window id 5822 at command start)`
- **AND** no tab of any other window is closed

#### Scenario: A tab found by its URL has moved

- **WHEN** user runs `safari-browser close --url work.example/a2`, the resolution finds it as tab 2 of window id 5822, and tab 2 of that window shows another URL when the close script runs
- **THEN** the command fails with a target-changed error
- **AND** no tab is closed

#### Scenario: No targeting flag

- **WHEN** user runs `safari-browser close` with no targeting flag and no `--profile`
- **THEN** the command sends the scripts it sent before this requirement, which name `window 1`

##### Example: references after the resolution

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Target at resolution | Window reference in every later AppleScript |
| --- | --- | --- |
| `close --window 2` | window 2 has id 5822 | `window id 5822` |
| `close --url work.example/a2` | tab 2 of window id 5822 | `tab 2 of window id 5822` |
| `close --window-id 5822 --tab-in-window 2` | window id 5822 | `tab 2 of window id 5822` |
| `pdf --allow-hid --window 2 out.pdf` | window 2 has id 5822 | `window id 5822` |
| `upload --native "input" f.txt --window 2` | window 2 has id 5822 | `window id 5822` |
| `screenshot --window 2 out.png` | window 2 has id 5822 | `window id 5822` |
| `open https://work.example/b1` | tab 1 of window id 6933 shows that URL | `window id 6933` |

##### Example: the URL check before acting

| Flag | URL the resolution read | URL of the tab when the script runs | Result |
| --- | --- | --- | --- |
| `--url work.example/a2` | `https://work.example/a2` | `https://work.example/a2?x=1` | acts |
| `--url work.example/a2` | `https://work.example/a2` | `https://work.example/A2` | target-changed error |
| `--url-exact https://work.example/a2` | `https://work.example/a2` | `https://work.example/a2#top` | target-changed error |
| `--url-endswith /a2` | `https://work.example/a2` | `https://other.example/a2` | acts |
| `--url-regex 'a[0-9]$'` | `https://work.example/a2` | `https://work.example/a2` | acts |
| `--url-regex 'a[0-9]$'` | `https://work.example/a2` | `https://work.example/a3` | target-changed error |
| `--url-regex` on a URL of 2,500 characters | that URL | a URL with the same first 2,000 characters | acts |
| `--tab-in-window 2` | (not read) | any URL | acts |

##### Example: cases that keep the position

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | State at command start | Window reference |
| --- | --- | --- |
| `close` | as above | `window 1`, scripts unchanged |
| `close --window 2` | the id of window 2 cannot be read | `window 2`, after the one note |
| `close --window 5` | as above | the one note, then the document-not-found error it gave before |
| `close --profile Work` | windows 2 and 3 belong to the profile `Work` | `window id 5822` |
| `close --window-id 5822` | the enumeration record of that window carries no id | `window id 5822`: a typed id is never a position |
| a tab found by `--url` | the enumeration record of its window carries no id | `window <n>` |
| `screenshot --profile Work out.png`, or `screenshot` with only `--url-exact`, `--url-endswith` or `--url-regex` | as above | no window is resolved and no AppleScript is sent for it; Safari's front window is captured (safari-browser#233) |

##### Example: what a target-changed error says

| Where the check failed | The error says |
| --- | --- |
| before any action of the command (`close`, `pdf`, `open`, the tab script of `upload`) | nothing was done to the tab: no tab was closed or switched, no window was raised, no keystroke was sent |
| `upload`, at the read or the click that follows its tab script | the command had already made that tab current when it was not; the file input was not clicked |
| `upload`, in the first Safari block of the dialog script, after the click | no window was raised and no keystroke was sent; the click may have opened a file dialog, to be dismissed (Esc) before a retry |

Each of the three names the target (`window id 5822 tab 2`) and none says that the target was resolved again.

##### Example: markers by number

| Error a script ended with | Result |
| --- | --- |
| any text, ending `(9001)` | target-changed error |
| any text, ending `(9002)` | document-not-found error |
| any text, ending `(9003)` | document-not-found error |
| a System Events error that names a window titled `SB_WINDOW_GONE`, `SB_TARGET_CHANGED` or `SB_TAB_GONE`, ending `(-1728)` | passed through unchanged |
| a Safari error ending `(-1728)`, in a step the command marks as a Safari read | document-not-found error |
| the same error, in any other step | passed through unchanged |

### Requirement: Tab auto-switch before keystroke dispatch

When the resolution names a tab, `pdf` and the native `upload` paths SHALL bring it forward before dispatching any keystroke: one AppleScript names the window and the tab as "Window-level commands act on the window they resolved" requires, runs that requirement's URL check when the tab was found by its URL, and makes the tab the window's current tab when it is not (`set current tab of window id <id> to tab <t> of window id <id>`). A tab that is already current is checked and left as it is. `pdf` SHALL do this inside its export script. `upload` SHALL do it in one AppleScript before it opens the file dialog, and SHALL then read the page and click the file input in that tab only while it is still the window's current tab; when another tab has become current, the upload SHALL stop with a target-changed error before the file dialog opens. When the tab was found by its URL, the URL that read returns SHALL still satisfy the flag; when it does not, the upload SHALL stop the same way. The dialog script SHALL then check the tab once more in its first Safari block, before it raises the window: that the window still has a tab at that position, that the tab passes the URL check when it was found by its URL, and that it is still the window's current tab. The dialog script SHALL NOT make a tab current. These checks of the read, the click and the dialog script apply when the window is named by its id. `close` and `screenshot` SHALL NOT switch tabs. The tab switch SHALL be classified as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag.

**Concurrent modification window** (#26 verify P1-3, safari-browser#353): the native-path workflow still spans several AppleScript runs: the resolver's enumeration, the tab switch of `upload`, its read that checks the target exists, and the script that sends the keystrokes. Safari's windows can change between them. Because every run after the resolution names the window by its id, a window that closed fails the command with a document-not-found error, and a window that moved in the window order is still the one acted on. A window that has fewer tabs than the position the resolution named fails the command with a document-not-found error, for every target that names a tab. A tab that moved inside its window, or whose position another tab took, is caught only for a tab found by its URL; a tab named by its position is not.

#### Scenario: Target URL in background tab of a window

- **WHEN** Safari window 1 has three tabs: `https://github.com/` (current), `https://web.plaud.ai/` (background), `https://news.ycombinator.com/` (background)
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL switch window 1's current tab to the plaud tab
- **AND** SHALL raise window 1 to the front
- **AND** SHALL dispatch the keystroke path against the now-active plaud tab

#### Scenario: Target URL already in current tab

- **WHEN** Safari window 1's current tab is already `https://web.plaud.ai/`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL check the tab's URL and SHALL NOT make any tab current
- **AND** SHALL proceed to raise and keystroke

#### Scenario: close does not switch tabs

- **WHEN** user runs `safari-browser close --url work.example/a2` and that tab is a background tab of its window
- **THEN** no AppleScript of the command makes another tab current

##### Example: tab switch scripts

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | Target | What happens to the tab before any keystroke |
| --- | --- | --- |
| `upload --native "input" f.txt --url work.example/a2` | background tab 2 of window id 5822 | one AppleScript: the URL check on `tab 2 of window id 5822`, then that tab is made current |
| `upload --native "input" f.txt --url work.example/a1` | current tab 1 of window id 5822 | one AppleScript: the URL check on `tab 1 of window id 5822`; no tab is made current |
| `upload --native "input" f.txt --window-id 5822 --tab-in-window 2` | background tab 2 of window id 5822 | one AppleScript, without a URL check; tab 2 is made current |
| `upload --native "input" f.txt --window 2` | window id 5822, no tab named | no AppleScript for this |
| `upload --native "input" f.txt --url work.example/a2`, when tab 1 is made current again after that AppleScript | tab 2 of window id 5822 | the upload stops with a target-changed error; the file input is not clicked |
| `upload --native "input" f.txt --url work.example/a2`, when tab 2 shows another URL after that AppleScript | tab 2 of window id 5822 | the upload stops with a target-changed error at the read; the file input is not clicked |
| `pdf --allow-hid --url work.example/a2 out.pdf` | background tab 2 of window id 5822 | inside the export script, before the window is raised: the URL check, then tab 2 is made current |
| `pdf --allow-hid --window-id 5822 --tab-in-window 2 out.pdf`, when window id 5822 has one tab by the time the export script runs | tab 2 of window id 5822 | the script stops with error number 9003 before any tab is made current or the window is raised; the miss names `window id 5822 tab 2` |
| `pdf --allow-hid --url work.example/a1 out.pdf` | current tab 1 of window id 5822 | inside the export script: the URL check; no tab is made current |
| `close --url work.example/a2` | background tab 2 of window id 5822 | nothing; `close` makes no tab current |
