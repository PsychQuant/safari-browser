## ADDED Requirements

### Requirement: URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment

A query string can be a credential: signed links keep their signature there, and an OAuth callback keeps its code or token in the query or fragment. The places below SHALL show the URL of a tab with everything from the first `?` or `#` removed, followed by `?…` when a query was removed or `#…` when only a fragment was, and with the credentials of an authority (`user:pass@`) replaced by `…@`. The cut SHALL NOT depend on the URL having a hierarchical form (`about:blank#x` and `data:` URLs are cut the same way), and the delimiters SHALL be found among Unicode scalars, so that a combining mark after `?` or `#` cannot hide them. The places are a closed list of six, and no other place is covered on the ground that it resembles one:

1. the listing of open tabs in `documentNotFound`;
2. the candidates of `ambiguousWindowMatch`;
3. the "Target position now shows" line of `targetTabChanged`;
4. the stderr warning that `--first-match` writes, and the listing it gives when nothing matches;
5. the note that `js` writes to stderr when the code navigated the page;
6. the error `upload` raises when the page navigated away during the upload.

The redaction SHALL be applied where the error's payload is built, not only where it is rendered, because a daemon's wire error and log line print the payload rather than the rendered description. Text around the URL (labels such as `window 1 [Work]:`, tab counts, `(unknown)`) SHALL be unchanged.

Not covered, and not by analogy: the person's own input (the `--url` pattern and the description of what was expected); the output of `documents`, `tabs` and `cloud-tabs`, which the person asks for directly; and the URLs of resources a command fetches or a page loads (`save-image` download errors, for example), which are a different class and are tracked separately (#229). The cut removes what follows the first `?` or `#` and the credentials of an authority; **a secret that is part of the path** (a reset link `/reset/<token>`, a webhook path) is not recognisable as one and is shown, because the host and path are what identify a tab.

#### Scenario: a signed URL in the not-found listing

- **WHEN** Safari has a tab at `https://cdn.example.org/f.pdf?X-Signature=SECRET` and the person runs `safari-browser get --url typo url`
- **THEN** the error lists `https://cdn.example.org/f.pdf?…`
- **AND** the string `SECRET` appears nowhere in the error, in its payload's own description, or in what a daemon prints for it

#### Scenario: ambiguous candidates in one window

- **WHEN** two tabs of one window match `--url cdn` and their URLs differ only in their queries
- **THEN** each candidate is listed as `[window N tab M] <scheme://host/path>?…` with its own tab number
- **AND** the message says that `safari-browser documents` prints the URLs in full and that `--window N --tab-in-window M` takes the numbers listed

#### Scenario: the first-match warning

- **WHEN** `--first-match` resolves among several tabs whose URLs carry queries
- **THEN** the stderr warning lists every candidate without its query and still says which tab was chosen

#### Scenario: a navigation note

- **WHEN** `js` navigates the page to `https://app.example/cb?code=SECRET#access_token=SECRET`
- **THEN** the note names `https://app.example/cb?…` and not the code or the token

#### Scenario: credentials and non-hierarchical URLs

- **WHEN** a tab's URL is `https://user:SECRET@host.example/x` or `about:blank#SECRET`
- **THEN** it is listed as `https://…@host.example/x` and `about:blank#…`

#### Scenario: a URL without a query

- **WHEN** a listed tab's URL has no query, fragment or credentials
- **THEN** it is shown exactly as it is

#### Scenario: a delimiter followed by a combining mark

- **WHEN** a tab's URL contains `?` followed by U+0301 and then a query
- **THEN** the query is still removed

## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list all currently available documents, each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and MUST say that `safari-browser documents` prints the URLs in full, so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`.

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

### Requirement: Window ambiguity surfaces deterministic error

When a `--url <pattern>` targeting flag matches more than one window's document URL, the system SHALL reject the invocation with `SafariBrowserError.ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, tabIndex: Int, url: String)])`. The error description MUST list every matching window index, tab index and URL (shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says) and MUST say that `safari-browser documents` prints the URLs in full, so the user can retarget with a more specific substring or with `--window N --tab-in-window M`. The system SHALL NOT silently select the first match.

#### Scenario: Multiple windows match URL substring

- **WHEN** Safari has three windows showing `https://web.plaud.ai/file/a`, `https://web.plaud.ai/file/b`, and `https://github.com/`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL throw `ambiguousWindowMatch` with `pattern: "plaud"` and `matches` containing both plaud window indices, tab indices and URLs
- **AND** the error description SHALL contain both `https://web.plaud.ai/file/a` and `https://web.plaud.ai/file/b`
- **AND** the system SHALL NOT perform any keystroke or window raise

#### Scenario: Specific substring resolves ambiguity

- **WHEN** Safari has three windows as above
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url "plaud.ai/file/a"`
- **THEN** the system SHALL resolve to the window showing `https://web.plaud.ai/file/a` unambiguously
- **AND** SHALL proceed with the keystroke dispatch
