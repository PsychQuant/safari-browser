## ADDED Requirements

### Requirement: Execute inline JavaScript

The system SHALL execute a JavaScript string in the current Safari tab using AppleScript `do JavaScript` and print the result to stdout.

#### Scenario: Simple JS expression

- **WHEN** user runs `safari-browser js "document.title"`
- **THEN** stdout contains the page title as a string

#### Scenario: JS returning object

- **WHEN** user runs `safari-browser js "JSON.stringify({a:1})"`
- **THEN** stdout contains `{"a":1}`

#### Scenario: JS execution error

- **WHEN** user runs `safari-browser js "undefinedVar.prop"`
- **THEN** the CLI exits with non-zero status and stderr contains the error message

### Requirement: Execute JavaScript from file

The system SHALL read a JavaScript file and execute its contents when `--file` flag is provided.

#### Scenario: Execute from file

- **WHEN** user runs `safari-browser js --file script.js` where `script.js` contains `document.title`
- **THEN** stdout contains the page title

#### Scenario: File not found

- **WHEN** user runs `safari-browser js --file nonexistent.js`
- **THEN** the CLI exits with non-zero status and stderr contains a file-not-found error
