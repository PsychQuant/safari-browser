# page-info Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: Get current URL

The system SHALL print the current tab's URL to stdout using Safari's native `URL` property.

#### Scenario: Get URL

- **WHEN** user runs `safari-browser get url`
- **THEN** stdout contains the current tab's URL (e.g., `https://example.com/page`)

---
### Requirement: Get page title

The system SHALL print the current tab's title to stdout using Safari's native `name` property.

#### Scenario: Get title

- **WHEN** user runs `safari-browser get title`
- **THEN** stdout contains the current tab's title

---
### Requirement: Get page text

The system SHALL print the current tab's plain text content to stdout using Safari's native `text` property.

#### Scenario: Get text

- **WHEN** user runs `safari-browser get text`
- **THEN** stdout contains the page's visible text content

---
### Requirement: Get page source

The system SHALL print the current tab's HTML source to stdout using Safari's native `source` property.

#### Scenario: Get source

- **WHEN** user runs `safari-browser get source`
- **THEN** stdout contains the full HTML source of the current page
