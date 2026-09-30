## ADDED Requirements

### Requirement: URLs of open tabs in targeting errors and warnings are shown without query or fragment

Wherever a targeting failure or warning lists the URL of an open tab — the `documentNotFound` listing, the `ambiguousWindowMatch` candidates, the "Target position now shows" line of `targetTabChanged`, and the `--first-match` stderr warning — the URL SHALL be shown with its query and fragment removed, and SHALL be followed by `?…` when a query was removed, or `#…` when only a fragment was. Text around the URL (labels such as `window 1 [Work]:`, tab counts, `(unknown)`) SHALL be unchanged. The delimiters SHALL be found among Unicode scalars, so that a combining mark after `?` or `#` cannot hide them.

This does not apply to the person's own input (the `--url` pattern and the description of what was expected), to the output of `documents`, `tabs` and `cloud-tabs`, which the person asks for directly, or to URLs of resources a command fetches.

#### Scenario: a signed URL in the not-found listing

- **WHEN** Safari has a tab at `https://cdn.example.org/f.pdf?X-Signature=SECRET` and the person runs `safari-browser get --url typo url`
- **THEN** the error lists `https://cdn.example.org/f.pdf?…`
- **AND** the string `SECRET` appears nowhere in the error

#### Scenario: ambiguous candidates

- **WHEN** two tabs match `--url cdn` and both have queries
- **THEN** each candidate is listed as `[window N] <scheme://host/path>?…`
- **AND** no query text appears

#### Scenario: the first-match warning

- **WHEN** `--first-match` resolves among several tabs whose URLs carry queries
- **THEN** the stderr warning lists every candidate without its query and still says which tab was chosen

#### Scenario: a URL without a query

- **WHEN** a listed tab's URL has no query and no fragment
- **THEN** it is shown exactly as it is

#### Scenario: a delimiter followed by a combining mark

- **WHEN** a tab's URL contains `?` followed by U+0301 and then a query
- **THEN** the query is still removed

## MODIFIED Requirements

### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list all currently available documents, each with its URL shown as the requirement "URLs of open tabs in targeting errors and warnings are shown without query or fragment" says, so the user can correct their target without running an additional command; `safari-browser documents` prints the URLs in full.

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
