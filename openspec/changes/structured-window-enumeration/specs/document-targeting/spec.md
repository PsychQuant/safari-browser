## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the tabs the miss is about — every tab for an unscoped miss; for a scoped miss fewer (a miss on one window's tab lists that window's tabs, a window-level miss lists each window's current tab) — each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and, whenever it lists any URL, MUST say that `safari-browser documents` prints the URLs in full (an empty listing has no URL to say it about), so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`. A missing window named by `--window-id` is the exception: it names one window and SHALL list no tab, except that with `--profile` it SHALL list that profile's windows by id. A listing narrowed by `--profile` SHALL name each listed window's id beside Safari's own window number (`window 3 tab 1 (window id 4711): …`; an enumeration record that carries no id says `(no window id)` instead), and its hint SHALL point at `--window-id W --tab-in-window M`, not at `--window N`, which with `--profile` counts only that profile's windows (#362). When the system enumerates Safari again to list what is open after a miss and that enumeration fails, the listing SHALL be one note saying that the open tabs could not be listed, naming only the kind of failure (an AppleScript error code, a timeout, a malformed list) and never the error's own text; it SHALL NOT say that no document, or no window of a profile, is open, and the hint SHALL NOT say that listed entries carry coordinates (#362).

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

#### Scenario: the enumeration after a miss fails

- **WHEN** a command's target is not found and the enumeration that would list the open tabs fails with AppleScript error -1712
- **THEN** the error lists one note saying the open tabs could not be listed, with `AppleScript error -1712`
- **AND** the error does not say that no document is open, nor that no window of a profile is open, and contains no text of the AppleScript error message

#### Scenario: the enumeration after a miss comes back malformed

- **WHEN** a command's target is not found and the enumeration that would list the open tabs fails with `windowEnumerationCorrupt`
- **THEN** the error lists one note saying the open tabs could not be listed, naming a malformed list
- **AND** the note contains no text of the corruption reason
