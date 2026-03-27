# file-upload Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Upload file via file dialog

The system SHALL click the element matching the CSS selector to trigger the file dialog, then use System Events to navigate to the file path via Cmd+Shift+G and confirm.

#### Scenario: Upload a file

- **WHEN** user runs `safari-browser upload "input[type='file']" "/path/to/file.mp3"`
- **THEN** the file input is clicked, the file dialog opens, the path is entered, and the file is selected

#### Scenario: File does not exist

- **WHEN** user runs `safari-browser upload "input[type='file']" "/nonexistent/file.mp3"`
- **THEN** the CLI exits with non-zero status and stderr contains a file-not-found error

#### Scenario: Element not found

- **WHEN** user runs `safari-browser upload ".nonexistent" "/path/to/file.mp3"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"
