## MODIFIED Requirements

### Requirement: Discovery aid for documentNotFound errors

Every tab that a `documentNotFound` listing names SHALL be a tab that `safari-browser documents` lists, with the same window and tab numbers, so a user experiencing a not-found error can run `safari-browser documents` and find the tab they meant. A listing that is not scoped names every tab in the same order; a listing scoped by its cause names fewer (a miss on one window's tab names that window's tabs; a window-level miss names each window's current tab, and a window without a tab as such). The two are not formatted alike, and they differ in what they show of a URL: the error's listing shows each URL redacted as the requirement "URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment" says, while `documents` prints URLs in full, because a person runs it on purpose to see them.

#### Scenario: Error listing matches documents output

- **WHEN** a `documentNotFound` error is raised with `availableDocuments` listing two URLs
- **AND** the user immediately runs `safari-browser documents`
- **THEN** both outputs SHALL refer to the same documents in the same index order

#### Scenario: a query is elided in the error and complete in documents

- **WHEN** a listed tab's URL is `https://cdn.example.org/f.pdf?X-Signature=SECRET`
- **THEN** the error's listing shows `https://cdn.example.org/f.pdf?…`
- **AND** `safari-browser documents` shows the full URL
