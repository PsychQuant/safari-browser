## MODIFIED Requirements

### Requirement: Get current URL

The system SHALL print the target document's URL to stdout using Safari's native `URL` property. The default target SHALL be `document 1` (equivalent to the front window's current tab in single-window usage). Any global targeting flag (`--url`, `--window`, `--tab`, `--document`) SHALL redirect the query to the resolved document. The query SHALL use a document-scoped AppleScript reference (`URL of document N` or equivalent) so that modal file dialog sheets on the front window do NOT block the request.

#### Scenario: Get URL with default target

- **WHEN** user runs `safari-browser get url`
- **THEN** stdout contains the URL of `document 1`

#### Scenario: Get URL from specific document by URL substring

- **WHEN** Safari has two documents `[https://example.com/, https://web.plaud.ai/]`
- **AND** user runs `safari-browser get --url plaud url`
- **THEN** stdout contains `https://web.plaud.ai/`

#### Scenario: Get URL while modal file dialog is open

- **WHEN** Safari's front window has an open modal file dialog sheet
- **AND** user runs `safari-browser get url`
- **THEN** the command SHALL return the document's URL within the default process timeout
- **AND** the command SHALL NOT hang waiting for the sheet to be dismissed

---
### Requirement: Get page title

The system SHALL print the target document's title to stdout using Safari's native `name` property on the document object. The default target SHALL be `document 1`. Global targeting flags SHALL redirect the query. Like `get url`, this query SHALL use document-scoped access so modal sheets do not block it.

#### Scenario: Get title with default target

- **WHEN** user runs `safari-browser get title`
- **THEN** stdout contains the title of `document 1`

#### Scenario: Get title by window index

- **WHEN** user runs `safari-browser get --window 2 title`
- **THEN** stdout contains the title of the document belonging to window 2

---
### Requirement: Get page text

The system SHALL print the target document's plain text content to stdout using Safari's native `text` property on the document object. The default target SHALL be `document 1`. Global targeting flags SHALL redirect the query. This query SHALL use document-scoped access.

#### Scenario: Get text with default target

- **WHEN** user runs `safari-browser get text`
- **THEN** stdout contains the visible text content of `document 1`

#### Scenario: Get text from targeted document

- **WHEN** user runs `safari-browser get --document 2 text`
- **THEN** stdout contains the visible text content of `document 2`

---
### Requirement: Get page source

The system SHALL print the target document's HTML source to stdout using Safari's native `source` property on the document object. The default target SHALL be `document 1`. Global targeting flags SHALL redirect the query. This query SHALL use document-scoped access.

#### Scenario: Get source with default target

- **WHEN** user runs `safari-browser get source`
- **THEN** stdout contains the full HTML source of `document 1`

#### Scenario: Get source from targeted document by URL

- **WHEN** Safari has two documents and user runs `safari-browser get --url plaud source`
- **THEN** stdout contains the HTML source of the document whose URL contains `plaud`
