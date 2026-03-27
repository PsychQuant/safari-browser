## ADDED Requirements

### Requirement: Build via Makefile

The system SHALL provide a Makefile with `build` target that runs `swift build -c release`.

#### Scenario: Build the project

- **WHEN** user runs `make build` in the repo root
- **THEN** `swift build -c release` executes and produces `.build/release/safari-browser`

### Requirement: Install via Makefile

The system SHALL provide a Makefile with `install` target that builds and copies the binary to `~/bin/safari-browser`.

#### Scenario: Install the binary

- **WHEN** user runs `make install` in the repo root
- **THEN** the binary is built and copied to `~/bin/safari-browser` with executable permissions

### Requirement: Clean via Makefile

The system SHALL provide a Makefile with `clean` target that removes the `.build/` directory.

#### Scenario: Clean build artifacts

- **WHEN** user runs `make clean` in the repo root
- **THEN** the `.build/` directory is removed

### Requirement: Git repository initialized

The system SHALL have a git repository with proper `.gitignore` excluding `.build/`, `.swiftpm/`, `Package.resolved`, and `references/`.

#### Scenario: Gitignore covers build artifacts

- **WHEN** user runs `git status` after a build
- **THEN** `.build/`, `.swiftpm/`, and `Package.resolved` are not shown as untracked files
