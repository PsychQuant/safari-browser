## ADDED Requirements

### Requirement: Execute safari-browser commands via reply tool

The system SHALL expose an MCP tool named `safari_action` that Claude Code can call to execute safari-browser CLI commands through the channel.

#### Scenario: Click via reply tool

- **WHEN** Claude Code calls `safari_action({ command: "click", args: ["button.submit"] })`
- **THEN** the channel server executes `safari-browser click "button.submit"` and returns the result

#### Scenario: Fill via reply tool

- **WHEN** Claude Code calls `safari_action({ command: "fill", args: ["input#email", "user@example.com"] })`
- **THEN** the channel server executes `safari-browser fill "input#email" "user@example.com"` and returns the result

### Requirement: Return command output

The system SHALL return the stdout of the safari-browser command as the tool result content.

#### Scenario: Get URL via reply tool

- **WHEN** Claude Code calls `safari_action({ command: "get", args: ["url"] })`
- **THEN** the tool result contains the current page URL

### Requirement: Command validation

The system SHALL reject commands that are not valid safari-browser subcommands.

#### Scenario: Invalid command

- **WHEN** Claude Code calls `safari_action({ command: "rm", args: ["-rf", "/"] })`
- **THEN** the tool returns an error indicating the command is not a valid safari-browser subcommand
