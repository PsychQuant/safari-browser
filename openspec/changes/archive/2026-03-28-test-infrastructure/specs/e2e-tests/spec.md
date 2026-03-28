## ADDED Requirements

### Requirement: E2E navigation test

The system SHALL verify that `open` navigates to a URL and `get url` returns the correct URL.

#### Scenario: Open and verify URL

- **WHEN** E2E test runs `safari-browser open <test-page>` then `safari-browser get url`
- **THEN** the returned URL contains the test page path

### Requirement: E2E JavaScript execution test

The system SHALL verify that `js` executes JS and returns the result.

#### Scenario: JS returns value

- **WHEN** E2E test runs `safari-browser js "1 + 1"`
- **THEN** stdout contains `2`

#### Scenario: JS returns page title

- **WHEN** E2E test runs `safari-browser js "document.title"` on the test page
- **THEN** stdout contains the test page title

### Requirement: E2E snapshot and ref test

The system SHALL verify that `snapshot` discovers elements and `@ref` works for interaction.

#### Scenario: Snapshot finds elements

- **WHEN** E2E test runs `safari-browser snapshot` on the test page with a form
- **THEN** stdout contains `@e1` and shows input/button elements

#### Scenario: Click by ref

- **WHEN** E2E test runs `safari-browser snapshot` then `safari-browser click @e1` on a link element
- **THEN** the page navigates (verified by `get url` changing)

### Requirement: E2E get info test

The system SHALL verify that `get text`, `get title` return non-empty content from the test page.

#### Scenario: Get title

- **WHEN** E2E test runs `safari-browser get title` on the test page
- **THEN** stdout contains "Safari Browser Test Page"

#### Scenario: Get text with selector

- **WHEN** E2E test runs `safari-browser get text "h1"` on the test page
- **THEN** stdout contains the h1 text content

### Requirement: E2E wait test

The system SHALL verify that `wait <ms>` pauses execution for the specified duration.

#### Scenario: Wait completes

- **WHEN** E2E test runs `safari-browser wait 500`
- **THEN** the command exits with status 0 after approximately 500ms

### Requirement: E2E error handling test

The system SHALL verify that commands exit with non-zero status on errors.

#### Scenario: Click nonexistent element

- **WHEN** E2E test runs `safari-browser click ".nonexistent"`
- **THEN** exit code is non-zero and stderr contains "Element not found"

#### Scenario: Invalid ref

- **WHEN** E2E test runs `safari-browser click @e99` (no snapshot taken or out of range)
- **THEN** exit code is non-zero

### Requirement: Test page fixture

The system SHALL provide a local HTML file at `Tests/Fixtures/test-page.html` containing: a heading, a link, a form with text input and submit button, a checkbox, a select dropdown, and a hidden element.

#### Scenario: Test page structure

- **WHEN** the test page is loaded in Safari
- **THEN** it contains h1, a, input[type=text], input[type=checkbox], select, button, and a div with display:none
