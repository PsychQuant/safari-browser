## ADDED Requirements

### Requirement: Element query commands honor document targeting

All element-query commands (`find`, `get html`, `get value`, `get attr`, `get count`, `get box`) SHALL execute their underlying JavaScript against the target document resolved from the global targeting flags. The default target SHALL be `document 1`. Global targeting flags (`--url`, `--window`, `--tab`, `--document`) SHALL redirect the query to the resolved document.

All element-query commands SHALL use document-scoped AppleScript references so modal file dialog sheets on the front window do NOT block read-only queries.

#### Scenario: Get HTML from specific document

- **WHEN** Safari has two documents and user runs `safari-browser --url plaud get html ".main"`
- **THEN** stdout contains the innerHTML of `.main` inside the document whose URL contains `plaud`

#### Scenario: Get count honors window targeting

- **WHEN** user runs `safari-browser --window 2 get count "a"`
- **THEN** stdout contains the count of `<a>` elements inside the document of window 2

#### Scenario: Get value honors document index

- **WHEN** user runs `safari-browser --document 3 get value "input#email"`
- **THEN** stdout contains the value of `input#email` inside document 3

#### Scenario: Get box honors targeting

- **WHEN** user runs `safari-browser --url plaud get box ".upload-button"`
- **THEN** stdout contains the bounding box JSON of `.upload-button` inside the matched document
- **AND** the coordinates SHALL be relative to that document's viewport

#### Scenario: Query while front window has modal sheet

- **WHEN** Safari's front window shows an open modal file dialog sheet
- **AND** user runs `safari-browser get count "button"`
- **THEN** the command returns the count within the default process timeout
- **AND** SHALL NOT hang waiting for the modal

#### Scenario: Element not found is scoped to target document

- **WHEN** Safari has two documents — only one contains `.missing`
- **AND** user runs `safari-browser --url plaud get html ".missing"`
- **AND** the `plaud` document does not contain `.missing`
- **THEN** the CLI SHALL exit with non-zero status and stderr SHALL contain `Element not found: .missing`
- **AND** SHALL NOT report the content from the other document
