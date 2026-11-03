## ADDED Requirements

### Requirement: pdf-cache names save-pdf when a tab has no cached copy

When `pdf-cache get` with a tab flag finds no cached record, its error SHALL add a line naming `safari-browser save-pdf`. `pdf-cache` SHALL NOT call it or read the tab's bytes.

#### Scenario: no cached record for the tab

- **WHEN** `pdf-cache get out.pdf --url "example.org/a.pdf"` finds no matching record
- **THEN** the error names `save-pdf`, and no JavaScript is evaluated
