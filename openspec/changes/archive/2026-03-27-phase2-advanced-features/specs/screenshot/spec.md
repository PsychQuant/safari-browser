## ADDED Requirements

### Requirement: Take window screenshot

The system SHALL capture the Safari front window using `screencapture -l <windowID>` and save it to the specified path (default: `screenshot.png`).

#### Scenario: Screenshot with default path

- **WHEN** user runs `safari-browser screenshot`
- **THEN** a PNG file is saved to `screenshot.png` in the current directory

#### Scenario: Screenshot with custom path

- **WHEN** user runs `safari-browser screenshot /tmp/page.png`
- **THEN** a PNG file is saved to `/tmp/page.png`

### Requirement: Take full page screenshot

The system SHALL capture the full scrollable page content when `--full` flag is provided. This is achieved by using JavaScript to get the full page dimensions, resizing the window temporarily, capturing, then restoring.

#### Scenario: Full page screenshot

- **WHEN** user runs `safari-browser screenshot --full /tmp/full.png`
- **THEN** a PNG capturing the entire scrollable page is saved to `/tmp/full.png`
