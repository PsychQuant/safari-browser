# build-and-install Specification

## Purpose

TBD - created by archiving change 'repo-setup-and-plugin'. Update Purpose after archive.

## Requirements

### Requirement: Build via Makefile

The system SHALL provide a Makefile with `build` target that runs `swift build -c release`.

#### Scenario: Build the project

- **WHEN** user runs `make build` in the repo root
- **THEN** `swift build -c release` executes and produces `.build/release/safari-browser`


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
### Requirement: Install via Makefile

The system SHALL provide a Makefile with `install` target that builds and copies the binary to `~/bin/safari-browser`.

#### Scenario: Install the binary

- **WHEN** user runs `make install` in the repo root
- **THEN** the binary is built and copied to `~/bin/safari-browser` with executable permissions


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
### Requirement: Clean via Makefile

The system SHALL provide a Makefile with `clean` target that removes the `.build/` directory.

#### Scenario: Clean build artifacts

- **WHEN** user runs `make clean` in the repo root
- **THEN** the `.build/` directory is removed


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
### Requirement: Git repository initialized

The system SHALL have a git repository with proper `.gitignore` excluding `.build/`, `.swiftpm/`, `Package.resolved`, and `references/`.

#### Scenario: Gitignore covers build artifacts

- **WHEN** user runs `git status` after a build
- **THEN** `.build/`, `.swiftpm/`, and `Package.resolved` are not shown as untracked files

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