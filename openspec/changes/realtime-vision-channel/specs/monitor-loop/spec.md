## ADDED Requirements

### Requirement: Periodic screenshot and analysis

The system SHALL take a screenshot of Safari's front window every N milliseconds (default 1500ms) and run FastVLM analysis on it.

#### Scenario: Default interval

- **WHEN** the channel server starts with no interval override
- **THEN** screenshots are taken every 1500ms

#### Scenario: Custom interval

- **WHEN** the channel server starts with environment variable `SB_CHANNEL_INTERVAL=3000`
- **THEN** screenshots are taken every 3000ms

### Requirement: Change detection

The system SHALL compare the current VLM description with the previous one and only push a notification when they differ.

#### Scenario: No change

- **WHEN** VLM produces the same description as the previous cycle
- **THEN** no notification is pushed

#### Scenario: Change detected

- **WHEN** VLM produces a different description from the previous cycle
- **THEN** a notification is pushed with the new description

### Requirement: Temporary file cleanup

The system SHALL delete screenshot files after analysis to avoid disk accumulation.

#### Scenario: Cleanup after analysis

- **WHEN** a screenshot is analyzed
- **THEN** the temporary PNG file is deleted
