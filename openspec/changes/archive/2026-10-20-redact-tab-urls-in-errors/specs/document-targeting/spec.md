## ADDED Requirements

### Requirement: URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment

A query string can be a credential: signed links keep their signature there, and an OAuth callback keeps its code or token in the query or fragment. The places below SHALL show the URL of a tab with these removed, each marked where it was:

- everything from the first `?` or `#`, followed by `?…` when a query was removed or `#…` when only a fragment was;
- the credentials of an authority (`user:pass@`), replaced by `…@` — including those of a URL that appears inside the path (`https://proxy.example/https://user:pass@host/`);
- path parameters (`;jsessionid=…`), replaced by `;…` up to the next `/`;
- the whole content of a `data:` or `javascript:` URL, shown as `data:…` / `javascript:…` (a closed pair; every other scheme is an address and keeps its path);
- whatever follows the first 200 scalars of scheme, host and path, ending in `…`.

The `?`/`#` cut SHALL NOT depend on the URL having a hierarchical form (`about:blank#x` is cut the same way), and the delimiters SHALL be found among Unicode scalars, so that a combining mark after `?` or `#` cannot hide them. The redaction SHALL be idempotent. The places are a closed list of six, and no other place is covered on the ground that it resembles one:

1. the listing of open tabs in `documentNotFound`;
2. the candidates of `ambiguousWindowMatch`;
3. the "Target position now shows" line of `targetTabChanged`;
4. the stderr warning that `--first-match` writes, and the listing it gives when nothing matches;
5. the note that `js` writes to stderr when the code navigated the page;
6. the error `upload` raises when the page navigated away during the upload.

The redaction SHALL be applied where the error's payload is built, because a daemon's wire error and the `error` field of its log line print the payload rather than the rendered description. `ambiguousWindowMatch` also redacts when it renders, which is harmless because the redaction is a fixed point. `targetTabChanged` carries its URL as a `RedactedURL`, a type that redacts what it is built from and has no string-literal conversion, so its payload cannot hold an unredacted URL; no producer passes a URL to it yet (all three pass none), so that guarantee is for the first one that does. `documentNotFound` has no such type: its strings are redacted where each of its producers builds them. Labels around the URL (such as `window 1 [Work]:`, tab counts, `(unknown)`) SHALL be unchanged, except that the candidates of `ambiguousWindowMatch` gain their tab number, `[window N tab M]`, because with the query removed it is what tells two tabs of one window apart. The messages that list URLs (the listing of `documentNotFound`, the candidates of `ambiguousWindowMatch`, and the `--first-match` warning) SHALL say that they are shown shortened and that `safari-browser documents` prints them in full — these three messages and no others, not by analogy: the `js` note, the `upload` error and the `targetTabChanged` line carry their own wording. A hint that tells the person how to retarget SHALL NOT promise that the number in front of a listed entry is what `--document N` takes: a listing can be scoped to one window or narrowed by `--profile`, and `--document N` numbers the tabs as `safari-browser documents` does. A hint SHALL NOT speak of listed URLs as if there were some when the listing is empty.

Not covered, and not by analogy: the person's own input (the `--url` pattern and the description of what was expected); the output of `documents`, `tabs` and `cloud-tabs`, which the person asks for directly; the `result` field of a daemon's log line, which records what a command returned (#230); and the URLs of resources a command fetches or a page loads (`save-image` download errors, for example), which are a different class and are tracked separately (#229). A secret that is part of the path (a reset link `/reset/<token>`, a webhook path) is not recognisable as one and is shown, because the host and path are what identify a tab; only what can be recognised is removed (a query, a fragment, credentials, path parameters, a data payload). A URL parser removes ASCII tab, LF and CR from anywhere, so the redaction removes them first, and what is shown has none. Where a parser and a plain reading of the text still differ, the redaction takes the reading that removes more: a backslash or an extra slash after a scheme begins an authority for credentials. The one exception goes the other way on purpose: the authority whose path parameters are removed starts after exactly two slashes, so in `file:///app;jsessionid=SECRET/x` the first segment is path and its parameter is removed. A URL inside a path that has fewer than two slashes after its scheme (`https:user:pw@host`) is not recognised as having an authority; Safari spells its own tab URLs canonically, and an embedded one is path text.

#### Scenario: a signed URL in the not-found listing

- **WHEN** Safari has a tab at `https://cdn.example.org/f.pdf?X-Signature=SECRET` and the person runs `safari-browser get --url typo url`
- **THEN** the error lists `https://cdn.example.org/f.pdf?…`
- **AND** the string `SECRET` appears nowhere in the error, in its payload's own description, or in what a daemon prints for the error (its wire error and the `error` field of its log line)

#### Scenario: ambiguous candidates in one window

- **WHEN** two tabs of one window match `--url cdn` and their URLs differ only in their queries
- **THEN** each candidate is listed as `[window N tab M] <scheme://host/path>?…` with its own tab number
- **AND** the message says that `safari-browser documents` prints the URLs in full and that `--window N --tab-in-window M` takes the numbers listed, and that with `--profile` the `--window` number counts only that profile's windows, whatever number is listed

#### Scenario: the first-match warning

- **WHEN** `--first-match` resolves among several tabs whose URLs carry queries
- **THEN** the stderr warning lists every candidate without its query and still says which tab was chosen
- **AND** the warning says that the URLs are shown shortened, so two entries that differ only in a part that is not shown do not read as a repeated line

#### Scenario: a navigation note

- **WHEN** `js` navigates the page to `https://app.example/cb?code=SECRET#access_token=SECRET`
- **THEN** the note names `https://app.example/cb?…` and not the code or the token

#### Scenario: an upload navigated away

- **WHEN** `upload --js` finds the page at another URL after a chunk, and the two URLs are `https://app.example/a?token=SECRET` and `https://app.example/b?token=SECRET`
- **THEN** the error names `https://app.example/a?…` and `https://app.example/b?…` and not the token
- **AND** when the two look the same once redacted (the raw URLs `https://app.example/a?token=A…` and `https://app.example/a?token=B…` both become `https://app.example/a?…`), the error says that they differ in a part that is not shown

#### Scenario: credentials and non-hierarchical URLs

- **WHEN** a tab's URL is `https://user:SECRET@host.example/x` or `about:blank#SECRET`
- **THEN** it is listed as `https://…@host.example/x` and `about:blank#…`

#### Scenario: credentials of a URL inside the path, path parameters and payload URLs

- **WHEN** a tab's URL is `https://proxy.example/fetch/https://user:SECRET@host.example/x`, `https://a.example/app;jsessionid=SECRET/next` or `data:text/plain,SECRET`
- **THEN** it is listed as `https://proxy.example/fetch/https://…@host.example/x`, `https://a.example/app;…/next` and `data:…`

#### Scenario: a scheme broken up by control characters, and extra slashes

- **WHEN** a tab's URL is `da` TAB `ta:text/plain,SECRET` (an ASCII tab inside the scheme), or `https://proxy.example/fetch/https:////user:SECRET@host.example/x`
- **THEN** it is listed as `data:…` and `https://proxy.example/fetch/https:////…@host.example/x`
- **AND** the string `SECRET` appears nowhere in what the error prints, including through `targetTabChanged`'s `RedactedURL`

#### Scenario: a very long URL

- **WHEN** a tab's URL, after the other rules have been applied, has more than 200 scalars of scheme, host and path
- **THEN** the listing shows the first 199 scalars of what is left after the other rules, followed by `…`, and a query after them is still shown as `?…`

#### Scenario: a URL with nothing to remove

- **WHEN** a listed tab's URL has no query, fragment, credentials or path parameters, is not a `data:` or `javascript:` URL and is not longer than 200 scalars
- **THEN** it is shown exactly as it is

#### Scenario: a delimiter followed by a combining mark

- **WHEN** a tab's URL contains `?` followed by U+0301 and then a query
- **THEN** the query is still removed

## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the tabs the miss is about — every tab for an unscoped miss; for a scoped miss fewer (a miss on one window's tab lists that window's tabs, a window-level miss lists each window's current tab) — each with its URL shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, and, whenever it lists any URL, MUST say that `safari-browser documents` prints the URLs in full (an empty listing has no URL to say it about), so the user can correct their target from the listing or, when the difference is in a query, from `safari-browser documents`.

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

When a `--url <pattern>` targeting flag matches the URLs of more than one tab (in one window or in several), the system SHALL reject the invocation with `SafariBrowserError.ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, tabIndex: Int, url: String)])`. The error description MUST list every matching window index, tab index and URL (shown as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says) and MUST say that `safari-browser documents` prints the URLs in full, so the user can retarget with a more specific substring or with `--window N --tab-in-window M` (the numbers listed are Safari's own window and tab numbers; with `--profile`, the `--window` number counts only that profile's windows, and the message SHALL say so). The system SHALL NOT silently select the first match.

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
