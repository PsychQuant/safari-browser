## ADDED Requirements

### Requirement: Window number resolved to its id at command start

The commands in the closed list below SHALL resolve `--window <n>`, and `--window <n> --tab-in-window <m>`, to the stable id of the window that is the `n`-th window when the command starts, once, after the command's own argument checks and before any other Apple event of the command, and SHALL then address that window as `--window-id <id>` addresses it (see "Target a window by its stable id"): without `--tab-in-window`, the current tab of that window at each Apple event; with `--tab-in-window <m>`, `tab <m> of window id <id>`, where `<m>` stays a position inside that window at each Apple event (#188). No AppleScript sent after the id was read SHALL address the target window by its position; an enumeration that lists every window is not addressing the target. `--window <n>` keeps its meaning: `n` counts windows from the front, and with `--profile <name>` it counts only that profile's windows, at the moment the command starts. Invalid arguments a command checks itself (a `scroll` direction, a `set media` scheme, a `press` key with no name, a `find` locator, an `exec` script that does not parse or exceeds `--max-steps`) SHALL be reported before Safari is contacted.

Without `--profile`, the id SHALL be read with one query that names window `n` (with `--tab-in-window <m>`, the same query SHALL also read the window's tab count, and the id SHALL be used only when `1 <= m <= tab count`); the query SHALL NOT probe for dialogs. With `--profile`, the id SHALL be the one a single profile-scoped enumeration reads for that window (for `--tab-in-window <m>`, the enumeration's tab `m` of that window), without a dialog probe; that enumeration SHALL be the profile check for the whole command, and later Apple events of the command SHALL NOT enumerate again to check the id against the profile (a window's profile does not change while it is open). An id that reaches a command already resolved (`exec` hands `--window-id <id>` with a private record of `<n>` to each step) SHALL be checked against `--profile` once, when the command starts.

When the id cannot be read — no `n`-th window, a window with no tab, a tab `m` outside the window, an enumeration record without a window id, or, without `--profile`, a query that does not answer — the command SHALL keep the positional target, so that its first step fails, or runs, exactly as it did before this requirement, and SHALL write one note to stderr saying that `--window <n>` is looked up by its position at each step. Under `--profile`, an enumeration that times out or fails SHALL be reported as the command's error, not retried by the first step. A cancelled command SHALL stop instead.

When the window whose id was read closes before a later step, or the tab `m` of it is gone, that step SHALL fail with a document-not-found error and SHALL NOT act on the window now in position `n`, on the front window, or on any other window. The error's pattern SHALL name what the user typed and the id, `window <n> (window id <id> at command start)` (with `--tab-in-window`, `window <n> tab <m> (window id <id> at command start)`), and its listing and hint SHALL be those of item 8 of "Document not found surfaces discoverable error". `js`, `wait` and `save-pdf` steps of an `exec` run that receive the resolved id SHALL name `<n>` the same way. Commands that resolve `--profile` once and pass no profile to their later calls (`get text`, `get html`, `save-image`, `upload` on its JavaScript path, `open`) list, for a window that is gone, the note of a window that is gone, not the profile's tabs.

The commands are a closed list: `back`, `check`, `uncheck`, `click`, `console`, `cookies get`, `cookies set`, `cookies clear`, `dblclick`, `drag`, `errors`, `fill`, `find`, `focus`, `forward`, every `get` subcommand, `highlight`, `hover`, every `is` subcommand, every `mouse` subcommand, `open` when it navigates (not `--new-tab` or `--new-window`), `press`, `reload`, `save-image`, `scroll`, `scrollintoview`, `select`, `set media`, `snapshot`, every `storage` subcommand, `tab is-marked`, `tab unmark`, `type`, `upload` on its JavaScript path (`--js`, or the default without Accessibility), and `exec` (only when some step, or the tab-ownership marker, uses the exec-level target). The exceptions are also a closed list, each for its own reason: `js`, `wait` and `save-pdf` already resolve `--window <n>` once at command start and additionally require the current tab not to change; `tabs`, `tab focus`, `tab new` and `open --new-tab` read the window's id themselves before acting; `tab <n>` with `--window <n>` and no `--profile` switches the tab in a single Apple event that names the window by its position; `pdf-cache get` reads one tab URL through a seam its tests inject, and nothing after it addresses the window; `close`, `screenshot`, `pdf`, and `upload` on its native paths are out of scope (safari-browser#353); `documents` and `wait <ms>` read no tab; and a command given no targeting flag keeps the front window, looked up at each Apple event (safari-browser#287). A command added later that composes the shared targeting options SHALL resolve `--window <n>` this way or be added to this list of exceptions.

`click --mark-tab` (and `--mark-tab-persist`) SHALL resolve the id before it reads and rewrites the title, so the wrap, the click and the unwrap address the same window by id.

The id read at command start is not carried to the next command: a second command started with `--window <n>` reads the `n`-th window again.

#### Scenario: A window raised mid-command does not redirect later steps

- **WHEN** user runs `safari-browser click --mark-tab --window 2 "#go"`
- **AND** window 2 has id 4711 when the command starts
- **AND** another window is raised to position 2 after the first Apple event
- **THEN** the title is read and wrapped, the element is clicked, and the title is unwrapped in `window id 4711`
- **AND** no AppleScript sent after the id was read addresses `window 2`

#### Scenario: A window closed mid-command fails closed

- **WHEN** user runs `safari-browser get text --window 2 "#log"`
- **AND** window 2 has id 4711 when the command starts and closes before the text is read
- **THEN** the command fails with a document-not-found error whose pattern is `window 2 (window id 4711 at command start)`
- **AND** no text is read from the window now in position 2 or from the front window

#### Scenario: A tab of a window number

- **WHEN** user runs `safari-browser get url --window 1 --tab-in-window 3`
- **AND** window 1 has id 4711 and five tabs when the command starts
- **THEN** every reference after the id was read is `tab 3 of window id 4711`

#### Scenario: The id cannot be read at command start

- **WHEN** user runs `safari-browser get url --window 5` and Safari has two windows
- **THEN** the command writes one note that `--window 5` is looked up by its position, keeps it as a position, and fails with the document-not-found error that lists the open windows, as it did before this requirement

#### Scenario: A tab outside the window at command start

- **WHEN** user runs `safari-browser get url --window 1 --tab-in-window 9` and window 1 has three tabs
- **THEN** the command keeps the positional target and fails with the document-not-found error it reported before this requirement

#### Scenario: Window number within a profile

- **WHEN** user runs `safari-browser click --mark-tab --window 1 --profile Work "#go"`
- **AND** the first window of the profile `Work` is Safari's window 3, whose id is 4711
- **THEN** the id 4711 is read from one profile-scoped enumeration at command start
- **AND** the title reads and writes and the click address `window id 4711` without enumerating the windows again

#### Scenario: A stuck Safari under a profile

- **WHEN** user runs `safari-browser get url --window 1 --profile Work` and the enumeration at command start times out
- **THEN** the command fails with that timeout after one enumeration

#### Scenario: Other targeting flags are not resolved

- **WHEN** user runs a listed command with `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--document`, `--tab`, `--window-id`, `--profile` alone, or no targeting flag
- **THEN** no AppleScript is sent to resolve a window id before the command's own steps

## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the tabs the miss is about — every tab for an unscoped miss; for a scoped miss fewer (a miss on one window's tab lists that window's tabs, a window-level miss lists each window's current tab) — each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and, whenever it lists any URL, MUST say that `safari-browser documents` prints the URLs in full (an empty listing has no URL to say it about), so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`. A missing window named by `--window-id` is the exception: it names one window and SHALL list no tab, except that with `--profile` it SHALL list that profile's windows, a window whose enumeration record has an id by that id and one whose record has none by Safari's number, marked `(no window id)`. A `--window N` that was resolved to its window id at command start (see "Window number resolved to its id at command start") and whose window or tab is gone later in the command is item 8 below, not item 2. When the system enumerates Safari again to list what is open after a miss and that enumeration fails, the listing SHALL be one note saying that the open tabs could not be listed, naming only the kind of failure (an AppleScript error code or a timeout) and never the error's own text; it SHALL NOT say that no document, or no window of a profile, is open, and the hint SHALL NOT say that listed entries carry coordinates (#362).

With `--profile`, `--window N` counts only that profile's windows, while a listing shows Safari's own window numbers, so a number copied from a listing into `--window N` with `--profile` can select another window (#362). When the target carries `--profile` (for item 2, when the target carries it or its caller passes it beside the target), the listings of the following misses SHALL name each listed window's id beside Safari's own window number (`window 3 tab 1 (window id 4711): …`), and an entry from an enumeration record that carries no id SHALL say `(no window id)` instead. Their hint SHALL NOT point at `--window N` with `--profile`, and SHALL say how each kind of entry is targeted: an entry that names an id with `--window-id W`, adding `--tab-in-window M` where the entry names a tab, with or without `--profile` (for item 7, without `--profile` or with the profile its brackets name); an entry marked `(no window id)` with `--window N`, adding `--tab-in-window M` where the entry names a tab, without `--profile`. When every entry names an id the hint gives only the first way, when no entry does only the second, and when the listing has both kinds of entry it gives both, each for its kind:

1. a resolved tab whose window is no longer there when the resolver checks it again: a `.resolvedTab` or `.anchoredCurrentTab` target that re-enters the resolver (`listing(_:within:scope:)`);
2. a tab that disappeared during a command, as `runTargetedAppleScript` translates the error, when the target carries the profile or its caller passes the profile beside a target that does not. The callers that pass it are these, and only these: `get url`, `get title` and `get source`; the bridge's text read (`getCurrentText`), which passes the profile so that the bridge treats it as it treats the three readers above, although no command passes a profile to it: the `get text` command resolves its target before calling it and passes none, so `get text` itself is unchanged (see the #368 exception); the JavaScript dispatch of `doJavaScript` for a `--window N` or `--window N --tab-in-window M` target that is still a position because its window id could not be read at command start (#354); and `close`. The miss line of this translation repeats the target as it was given to the translation: what was typed, which for `--window N --profile P` is the profile's ordinal while the entries show Safari's numbers, or, for `close`, the Safari number the resolver produced;
3. a URL target (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`) that matches no tab;
4. `--window N --tab-in-window M` whose tab number is out of range in that window;
5. `--document N` with `N` below 1, which only a direct caller of the resolver can produce: the command line rejects `--document` below 1 before any target is resolved;
6. `--document N` beyond the last tab, whose entries name windows, not tabs;
7. a target other than `--window-id` whose `--profile` matches no open window when the resolver filters the windows by profile (`pickNativeTarget`). Its listing names every open window, each with its profile in brackets, or `[(no profile)]` for a window that has none (no `--profile` selects such a window), and its id (`window 2 [Work] (window id 303): …`). Its hint says that no window of that profile is open; when some listed window has a profile, that the listed windows belong to other profiles and to check the `--profile` name against them, and when none has, that none of them has a profile and no `--profile` selects them; when some listed entry names an id, that `--window-id W` selects that window without `--profile`, or, where its brackets name a profile, with that profile (not with the `--profile` that was given, which matches no window); and that an entry without an id is targeted with `--window N` without `--profile`. When no entry names an id, the hint gives only that last way. The other misses for a profile with no open window (a `--window-id` target, the translation in item 2, a resolved tab that carries the profile, and `tabs` when the profile's last window closes during the command and its record carried an id; when the record had none, `tabs` resolves what was typed again and gets this item's listing) list only the note `(no window of profile "P" is open)`, under the last exception below.
8. a `--window N` or `--window N --tab-in-window M` target resolved to its window id at command start whose window or tab is gone later in the command (#354). Its pattern names what was typed and the id, `window N (window id W at command start)` or `window N tab M (window id W at command start)`. A tab that is gone from a window that is still open lists that window's tabs, with or without `--profile`. A window that is gone lists, when the caller passes the profile beside the target (the callers of item 2 and every command that passes `--profile` to each call), that profile's tabs, or the note `(no window of profile "P" is open)`; without the profile it lists one note saying the window is no longer open and that the command did not move on to the window now in that position, and its hint says the same and points at `safari-browser documents`.

This list is closed: no other listing is promised to name window ids, by analogy or otherwise. These listings under `--profile` do not, each for its own reason:

- the window-out-of-range misses of `--window N` and `--window N --tab-in-window M` label each window by the profile's own ordinal, adding `(Safari window N)` where the two differ, and `--window N` takes that ordinal correctly under `--profile`;
- a `--window-id` miss under `--profile` (whose listing `tabs` also reports when the window it read closed) and `--window-id W --tab-in-window M` with a tab out of range name each window that has an id by that id alone (`window id 303: …`), with no Safari number beside it. A record without an id is named by Safari's number instead (`window 3 (no window id): …`), and the hint treats these entries as it treats the entries of the list above, with and without an id;
- the translation for callers that hand it a positional target without the profile, which are not yet scoped; they list every profile's tabs with Safari's numbers. `upload --native` and `upload --allow-hid` (the preflight URL read and the click) and the window check of `screenshot` build that target from the Safari window number the resolver produced, whatever target flag was given; only #353 (native-path commands by window id) removes it. The follow-up reads (length, chunks, cleanup) of a large JavaScript result (`doJavaScriptLarge`, which `snapshot` uses) receive the typed `--window N` or `--window N --tab-in-window M` target without the profile, and also address Safari's window N rather than the profile's, only when the window id could not be read at command start; when it was read (#354), they receive that id, which names the profile's window. The bridge's dropping of the profile on those reads stays tracked in #372;
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

#### Scenario: a pinned window that closes under a profile lists the profile's tabs by id

- **WHEN** the windows of the profile `Work` are Safari windows 2 and 3, with ids 303 and 404, and user runs `safari-browser get url --window 2 --profile Work`
- **AND** window 404 closes after the command read its id and before it reads the URL
- **THEN** the pattern is `window 2 (window id 404 at command start)`, the listing is `window 2 tab 1 (window id 303): …` and the other tabs of `Work`, and no tab of another profile
- **AND** the hint points at `--window-id W`, not at `--window N`

