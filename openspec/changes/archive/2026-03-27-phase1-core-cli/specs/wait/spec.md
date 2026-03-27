## ADDED Requirements

### Requirement: Wait for duration

The system SHALL pause execution for the specified number of milliseconds.

#### Scenario: Wait 2 seconds

- **WHEN** user runs `safari-browser wait 2000`
- **THEN** the CLI blocks for approximately 2000ms before exiting

### Requirement: Wait for URL pattern

The system SHALL poll the current tab's URL until it matches the given pattern, then exit.

#### Scenario: URL matches pattern

- **WHEN** user runs `safari-browser wait --url "dashboard"` and the current URL eventually contains "dashboard"
- **THEN** the CLI exits with zero status once the URL contains "dashboard"

#### Scenario: URL timeout

- **WHEN** user runs `safari-browser wait --url "never-match" --timeout 5000` and the URL never matches within 5 seconds
- **THEN** the CLI exits with non-zero status and stderr contains a timeout error

### Requirement: Wait for JS condition

The system SHALL poll a JavaScript expression until it evaluates to a truthy value, then exit.

#### Scenario: JS condition becomes true

- **WHEN** user runs `safari-browser wait --js "document.querySelector('.loaded')"` and the element eventually appears
- **THEN** the CLI exits with zero status once the expression is truthy

#### Scenario: JS condition timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 3000`
- **THEN** the CLI exits with non-zero status after 3 seconds with a timeout error

### Requirement: Default timeout

The system SHALL use a default timeout of 30000ms (30 seconds) for `--url` and `--js` wait operations when `--timeout` is not specified.

#### Scenario: Default timeout applied

- **WHEN** user runs `safari-browser wait --url "never"` without `--timeout`
- **THEN** the CLI times out after 30 seconds
