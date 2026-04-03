## ADDED Requirements

### Requirement: MCP server with channel capability

The system SHALL implement a Bun MCP server that declares `claude/channel` experimental capability and connects to Claude Code via stdio transport.

#### Scenario: Claude Code spawns channel server

- **WHEN** Claude Code starts with `--channels plugin:safari-browser@psychquant-claude-plugins`
- **THEN** the channel server starts, connects via stdio, and registers the notification listener

### Requirement: Push page change notifications

The system SHALL emit `notifications/claude/channel` events with content (text description) and meta (event type, timestamp) when page changes are detected.

#### Scenario: Page change detected

- **WHEN** the monitor loop detects a page state change
- **THEN** a notification is pushed with source "safari-vision", content containing the VLM description, and meta including event type and timestamp

### Requirement: Channel instructions

The server SHALL provide instructions string describing event format so Claude Code knows how to interpret incoming channel events.

#### Scenario: Claude receives instructions

- **WHEN** the channel server connects
- **THEN** Claude Code's system prompt includes instructions explaining `<channel source="safari-vision">` tag format
