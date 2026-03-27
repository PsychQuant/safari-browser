## ADDED Requirements

### Requirement: Set color scheme preference

The system SHALL override the CSS `prefers-color-scheme` media query by injecting a style element that forces dark or light mode on the page.

#### Scenario: Set dark mode

- **WHEN** user runs `safari-browser set media dark`
- **THEN** the page renders as if `prefers-color-scheme: dark` is active

#### Scenario: Set light mode

- **WHEN** user runs `safari-browser set media light`
- **THEN** the page renders as if `prefers-color-scheme: light` is active
