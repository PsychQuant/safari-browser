## ADDED Requirements

### Requirement: Export page as PDF

The system SHALL export the current Safari page as PDF using System Events to trigger File > Export as PDF, saving to the specified path.

#### Scenario: Export to PDF

- **WHEN** user runs `safari-browser pdf /tmp/page.pdf`
- **THEN** the current page is exported as PDF to `/tmp/page.pdf`

#### Scenario: Default path

- **WHEN** user runs `safari-browser pdf` without a path argument
- **THEN** the page is exported as PDF to `page.pdf` in the current directory
