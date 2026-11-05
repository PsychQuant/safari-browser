## ADDED Requirements

### Requirement: Target a window by its stable id

The system SHALL accept a global `--window-id <id>` flag on every subcommand that composes the shared targeting options. The value SHALL be a positive integer naming a Safari window by its AppleScript `id of window`, which does not change while the window exists. Without `--tab-in-window`, the target SHALL be the current tab of that window: `js`, `wait` and `save-pdf` SHALL read its index once at command start and fail if a different tab becomes current (the same check `--window <n>` has); other commands SHALL address it as `document of window id <id>`, that window's current tab at each Apple event, with or without `--profile`. With `--tab-in-window <m>`, the target SHALL be the `m`-th tab of that window, referenced as `tab m of window id <id>`; `js`, `wait` and `save-pdf` SHALL check that it exists before running anything.

`--window-id` SHALL be mutually exclusive with `--window`, `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--tab` and `--document`; a combination SHALL be rejected with a validation error before Safari is contacted. `--tab-in-window` SHALL be accepted with either `--window` or `--window-id`. When `--profile <name>` is also given, the window SHALL belong to that profile; otherwise the command SHALL fail without acting. When no window has the given id, or the window has no tab `m`, the command SHALL fail with a document-not-found error and SHALL NOT fall back to the front window or to any other window; without `--profile` the error SHALL list no window's tabs, and it SHALL point at the window ids rather than at `--window <n>`. When the profile check fails, the error SHALL list only the windows of the requested profile, and when that profile has no window open it SHALL list none. A value below 1 SHALL be rejected with a validation error. `close`, `screenshot`, `pdf`, and `upload` on its native paths (`--native`, `--allow-hid`, or the default when Accessibility is granted) SHALL find the window by its id; acting on it by id end to end is out of scope here (safari-browser#353). This list of commands is closed. `documents` lists every tab and `wait <ms>` / `wait --jitter` read no tab: they accept the flag and do not use it, as they do `--window <n>`.

#### Scenario: Current tab of a window by id

- **WHEN** user runs `safari-browser get url --window-id 4711`
- **AND** Safari has a window whose id is 4711 and whose current tab shows `https://example.com/a`
- **THEN** the command prints `https://example.com/a`

#### Scenario: A tab of a window by id

- **WHEN** user runs `safari-browser js --window-id 4711 --tab-in-window 2 "document.title"`
- **THEN** the script runs in `tab 2 of window id 4711`
- **AND** a change of window order between resolution and execution does not redirect it

#### Scenario: Window id that does not exist

- **WHEN** user runs `safari-browser get url --window-id 9999`
- **AND** no Safari window has the id 9999
- **THEN** the command fails with a document-not-found error
- **AND** no JavaScript runs in any tab and no tab or window is changed

#### Scenario: Tab that does not exist in a window named by id

- **WHEN** user runs `safari-browser js --window-id 4711 --tab-in-window 9 "1"`
- **AND** window 4711 has three tabs
- **THEN** the command fails with a document-not-found error
- **AND** the script runs in no tab

#### Scenario: Window id outside the requested profile

- **WHEN** user runs `safari-browser get url --window-id 4711 --profile Work`
- **AND** window 4711 belongs to the profile `Personal`
- **THEN** the command fails without reading the window

#### Scenario: Window id with a profile that has no window open

- **WHEN** user runs `safari-browser get url --window-id 4711 --profile Work`
- **AND** no window of the profile `Work` is open
- **THEN** the command fails with a document-not-found error
- **AND** the error lists no tab URL of any other profile

#### Scenario: Window id combined with another targeting flag

- **WHEN** user runs `safari-browser get url --window-id 4711 --window 1`
- **THEN** the system rejects the invocation with a validation error naming both flags

#### Scenario: Window id below one

- **WHEN** user runs `safari-browser get url --window-id 0`
- **THEN** the system rejects the invocation with a validation error

#### Scenario: Window id in an exec script

- **WHEN** user runs `safari-browser exec --window-id 4711` with a script whose steps read the page
- **THEN** every step targets the current tab of window 4711 in the in-process path and in the subprocess path alike

## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the tabs the miss is about — every tab for an unscoped miss; for a scoped miss fewer (a miss on one window's tab lists that window's tabs, a window-level miss lists each window's current tab) — each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and, whenever it lists any URL, MUST say that `safari-browser documents` prints the URLs in full (an empty listing has no URL to say it about), so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`. A miss on `--window-id` is the exception: it names one window and SHALL list no tab, except that with `--profile` it SHALL list that profile's windows by id.

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

### Requirement: Target document selection via CLI flags

The system SHALL provide a set of global CLI flags that select the target Safari document for any subsequent subcommand. The flags fall into three mutually exclusive groups:

1. **URL-matching flags** (all mutually exclusive with each other and with the remaining groups): `--url <substring>`, `--url-exact <url>`, `--url-endswith <suffix>`, `--url-regex <pattern>`.
2. **Index-based flags** (mutually exclusive with each other and with group 1): `--window <n>`, `--window-id <id>`, `--tab <n>`, `--document <n>`. `--window <n>` counts windows from the front; `--window-id <id>` names a window by its stable id (see "Target a window by its stable id").
3. **Composite same-URL escape hatch**: `--window <n>` or `--window-id <id>` combined with `--tab-in-window <m>` targets the `m`-th tab of that window. This composite SHALL be rejected if paired with any flag from group 1, or with `--tab` or `--document`.

If no target flag is provided, the system SHALL default to the first document in Safari's document collection (`document 1`). If more than one flag is supplied in a way that violates the exclusivity rules, the system SHALL reject the invocation with a validation error before executing the subcommand.

#### Scenario: Default targeting with no flags

- **WHEN** user runs `safari-browser get url` with no target flag
- **THEN** the system resolves the target to `document 1` of Safari
- **AND** the command returns the URL of that document

#### Scenario: URL substring targeting

- **WHEN** user runs `safari-browser get --url "plaud" url`
- **AND** Safari has multiple documents, one of which has `https://web.plaud.ai/` as its URL
- **THEN** the system resolves the target to the first document whose URL contains the substring `plaud`
- **AND** the command returns `https://web.plaud.ai/`

#### Scenario: URL exact targeting

- **WHEN** user runs `safari-browser get --url-exact "https://web.plaud.ai/" url`
- **AND** Safari has a document whose URL equals `https://web.plaud.ai/` exactly
- **THEN** the system resolves the target to that document
- **AND** the command returns `https://web.plaud.ai/`

#### Scenario: URL endsWith targeting

- **WHEN** user runs `safari-browser get --url-endswith "/play" url`
- **AND** Safari has a document whose URL ends with `/play`
- **THEN** the system resolves the target to that document
- **AND** the command returns the full URL of that document

#### Scenario: URL regex targeting

- **WHEN** user runs `safari-browser get --url-regex "lesson/[a-f0-9-]+$" url`
- **AND** Safari has a document whose URL matches the regex
- **THEN** the system resolves the target to that document
- **AND** the command returns the full URL

#### Scenario: Window index targeting

- **WHEN** user runs `safari-browser get --window 2 url`
- **AND** Safari has at least two windows
- **THEN** the system resolves the target to the document of the second window (1-indexed)
- **AND** the command returns that window's document URL

#### Scenario: Document index targeting

- **WHEN** user runs `safari-browser get --document 3 url`
- **AND** Safari has at least three documents in its document collection
- **THEN** the system resolves the target to `document 3`
- **AND** the command returns that document's URL

#### Scenario: Tab alias for document

- **WHEN** user runs `safari-browser get --tab 2 url`
- **THEN** the system treats `--tab 2` identically to `--document 2`
- **AND** the command returns the URL of `document 2`

#### Scenario: Mutually exclusive URL flags rejected

- **WHEN** user runs `safari-browser get url --url plaud --url-endswith /play`
- **THEN** the system SHALL print a usage error identifying the conflicting URL flags
- **AND** the system SHALL exit with a non-zero status before invoking any Safari operation

#### Scenario: URL flag combined with window index rejected

- **WHEN** user runs `safari-browser get url --url plaud --window 2`
- **THEN** the system SHALL print a usage error identifying the mutually exclusive flags
- **AND** the system SHALL exit with a non-zero status before invoking any Safari operation

### Requirement: Composite targeting flag --tab-in-window

The CLI SHALL accept a new flag `--tab-in-window N` (1-indexed) that selects a specific tab within a Safari window. This flag SHALL be valid only when paired with `--window M` or `--window-id W`; supplying `--tab-in-window` without either SHALL produce a validation error before any AppleScript executes.

When both `--window M` and `--tab-in-window N` are supplied, the resolver SHALL target the Nth tab of the Mth window as enumerated by `tabs of windows`; with `--window-id W` it SHALL target `tab N of window id W`. This provides a structured addressing mechanism for tabs that share an identical URL and cannot be disambiguated through `--url <substring>`.

`--tab-in-window` SHALL be mutually exclusive with `--url`, `--tab`, and `--document` (the existing exclusivity contract extends to this new flag).

#### Scenario: --tab-in-window requires --window

- **WHEN** user runs `safari-browser get url --tab-in-window 2` without supplying `--window`
- **THEN** the CLI SHALL exit with a validation error stating that `--tab-in-window` requires `--window`
- **AND** no AppleScript SHALL execute

#### Scenario: --window + --tab-in-window resolves correctly

- **WHEN** Safari has window 1 with three tabs (`a`, `b`, `c` in order) and user runs `safari-browser get url --window 1 --tab-in-window 2`
- **THEN** the command SHALL return the URL of tab `b`

#### Scenario: Disambiguate same-URL tabs via composite flag

- **WHEN** window 1 contains two tabs both at `https://web.plaud.ai/` (tab indices 1 and 2)
- **AND** user runs `safari-browser click "button.upload" --window 1 --tab-in-window 2`
- **THEN** the command SHALL act on the second tab specifically
- **AND** the first tab SHALL remain unaffected
