## MODIFIED Requirements

### Requirement: Execute inline JavaScript

The system SHALL execute a JavaScript string in the target Safari document using AppleScript `do JavaScript ... in <document reference>` and print the result to stdout. The default target SHALL be `document 1`. Global targeting flags (`--url`, `--window`, `--tab`, `--document`) SHALL redirect JavaScript execution to the resolved document. Execution SHALL use document-scoped AppleScript reference so modal file dialog sheets on the front window do NOT block the query.

#### Scenario: Simple JS expression with default target

- **WHEN** user runs `safari-browser js "document.title"`
- **THEN** stdout contains the page title of `document 1` as a string

#### Scenario: JS returning object

- **WHEN** user runs `safari-browser js "JSON.stringify({a:1})"`
- **THEN** stdout contains `{"a":1}`

#### Scenario: JS in targeted document by URL

- **WHEN** Safari has two documents and user runs `safari-browser js --url plaud "window.location.href"`
- **THEN** stdout contains the URL of the document whose URL contains `plaud`
- **AND** SHALL NOT return the URL of any other document

#### Scenario: JS in targeted document by window

- **WHEN** user runs `safari-browser js --window 2 "document.title"`
- **THEN** stdout contains the title of the document belonging to window 2

#### Scenario: JS execution error in targeted document

- **WHEN** user runs `safari-browser js --url plaud "undefinedVar.prop"`
- **AND** the matched document evaluates the script and raises a reference error
- **THEN** the CLI exits with non-zero status and stderr contains the JavaScript error message
- **AND** SHALL NOT leak errors from any other document

#### Scenario: JS while front window has modal sheet

- **WHEN** Safari's front window has an open modal file dialog sheet
- **AND** user runs `safari-browser js "1+1"`
- **THEN** the command SHALL return `2` within the default process timeout
- **AND** SHALL NOT hang

---
### Requirement: Execute JavaScript from file

The system SHALL read a JavaScript file and execute its contents in the target document when `--file` flag is provided. Target resolution rules SHALL be identical to `js <code>` — the default target is `document 1`, and global targeting flags redirect to the resolved document.

#### Scenario: Execute from file with default target

- **WHEN** user runs `safari-browser js --file script.js` where `script.js` contains `document.title`
- **THEN** stdout contains the title of `document 1`

#### Scenario: Execute from file in targeted document

- **WHEN** user runs `safari-browser js --file script.js --url plaud`
- **THEN** the script runs against the document whose URL contains `plaud`

#### Scenario: File not found

- **WHEN** user runs `safari-browser js --file nonexistent.js`
- **THEN** the CLI exits with non-zero status and stderr contains a file-not-found error
