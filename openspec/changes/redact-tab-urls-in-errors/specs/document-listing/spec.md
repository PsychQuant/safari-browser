## MODIFIED Requirements

### Requirement: Discovery aid for documentNotFound errors

For the listings in `SafariBrowserError.documentNotFound` that enumerate tabs (a URL miss, and a miss on a window's tab), the `documents` subcommand SHALL identify the same documents, in the same index order, so users experiencing a not-found error can run `safari-browser documents` and find the tab they meant. Listings of windows (a window miss, a profile with no window) show each window's current tab only, and a count for a zero-tab window. Only the set of documents and their order are specified to be the same; the two are not formatted alike (the coordinates, the markers, the title, the profile column and any dialog notes are not part of that), and they differ in what they show of a URL: the error's listing shows each URL redacted as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, while `documents` prints URLs in full, because a person runs it on purpose to see them.

#### Scenario: Error listing matches documents output

- **WHEN** a `documentNotFound` error is raised with `availableDocuments` listing two URLs
- **AND** the user immediately runs `safari-browser documents`
- **THEN** both outputs SHALL refer to the same documents in the same index order

#### Scenario: a query is elided in the error and complete in documents

- **WHEN** a listed tab's URL is `https://cdn.example.org/f.pdf?X-Signature=SECRET`
- **THEN** the error's listing shows `https://cdn.example.org/f.pdf?…`
- **AND** `safari-browser documents` shows the full URL
