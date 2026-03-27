# claude-plugin Specification

## Purpose

TBD - created by archiving change 'repo-setup-and-plugin'. Update Purpose after archive.

## Requirements

### Requirement: Plugin structure in psychquant-claude-plugins

The system SHALL create a `plugins/safari-browser/` directory in psychquant-claude-plugins with `plugin.json`, skills, and hooks following the existing plugin conventions.

#### Scenario: Plugin directory exists

- **WHEN** user inspects `psychquant-claude-plugins/plugins/safari-browser/`
- **THEN** it contains `plugin.json`, `skills/safari-browser/SKILL.md`, and `hooks/hooks.json` + `hooks/check-cli.sh`


<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->

---
### Requirement: SKILL.md teaches CLI usage and routing

The SKILL.md SHALL explain when to use safari-browser vs agent-browser, list all available commands, and provide usage examples. It SHALL set `allowed-tools` to permit `Bash(safari-browser:*)`.

#### Scenario: Claude selects safari-browser for login-required site

- **WHEN** user asks Claude to automate a website that requires login (e.g., Plaud, Elementor)
- **THEN** the skill triggers and Claude uses `safari-browser` commands instead of `agent-browser`

#### Scenario: Claude selects agent-browser for public site in CI

- **WHEN** user needs headless browser automation for a public site
- **THEN** the skill does NOT trigger, allowing agent-browser to be used


<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->

---
### Requirement: SessionStart hook checks CLI availability

The hooks SHALL check if `safari-browser` binary exists at `~/bin/safari-browser` on session start. If missing, it SHALL print instructions to build from source.

#### Scenario: Binary exists

- **WHEN** session starts and `~/bin/safari-browser` exists
- **THEN** hook prints version info (e.g., "✓ safari-browser installed")

#### Scenario: Binary missing

- **WHEN** session starts and `~/bin/safari-browser` does not exist
- **THEN** hook prints "⚠️ safari-browser not found" with build instructions: `cd ~/Developer/safari-browser && make install`

<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->