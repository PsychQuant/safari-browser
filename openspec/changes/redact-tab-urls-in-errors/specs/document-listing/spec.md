## MODIFIED Requirements

### Requirement: Discovery aid for documentNotFound errors

The `documents` subcommand SHALL identify the same documents, in the same index order, as the `availableDocuments` listing embedded in `SafariBrowserError.documentNotFound` error descriptions, so users experiencing a not-found error can run `safari-browser documents` and find the tab they meant. The two are not formatted alike (the coordinates, the current-tab marker, the title and the profile column differ), and they differ in what they show of a URL: the error's listing shows each URL without its query and fragment, while `documents` prints URLs in full, because a person runs it on purpose to see them.

#### Scenario: Error listing matches documents output

- **WHEN** a `documentNotFound` error is raised with `availableDocuments` listing two URLs
- **AND** the user immediately runs `safari-browser documents`
- **THEN** both outputs SHALL refer to the same documents in the same index order

#### Scenario: a query is elided in the error and complete in documents

- **WHEN** a listed tab's URL is `https://cdn.example.org/f.pdf?X-Signature=SECRET`
- **THEN** the error's listing shows `https://cdn.example.org/f.pdf?…`
- **AND** `safari-browser documents` shows the full URL
