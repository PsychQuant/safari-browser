## MODIFIED Requirements

### Requirement: Build via Makefile

The system SHALL provide a Makefile with a `build` target that runs `swift build -c release`. Before the compiler runs, the target SHALL stamp the build version into the tracked `Sources/SafariBrowser/BuildVersion.swift` through `scripts/stamp-version.sh`, and SHALL restore the tracked placeholder when the build ends, whether the build succeeded, failed, or was interrupted. The `install` and `install-signed` targets depend on `build` and therefore stamp as well.

#### Scenario: Build the project

- **WHEN** user runs `make build` in the repo root
- **THEN** `swift build -c release` executes and produces `.build/release/safari-browser`

#### Scenario: The built binary carries the version

- **WHEN** user runs `make build` in a git checkout
- **THEN** `.build/release/safari-browser --version` prints the output of `git describe --tags --match 'v[0-9]*' --always --dirty` computed before stamping

#### Scenario: The working tree is left unchanged by a successful build

- **GIVEN** a clean working tree
- **WHEN** user runs `make build` and it succeeds
- **THEN** `git status --porcelain` prints nothing

#### Scenario: The working tree is left unchanged by a failed build

- **GIVEN** a clean working tree and a build that fails during compilation
- **WHEN** user runs `make build`
- **THEN** `make build` exits non-zero and `Sources/SafariBrowser/BuildVersion.swift` has its tracked placeholder content again

#### Scenario: The working tree is left unchanged by an interrupted build

- **GIVEN** a build in progress
- **WHEN** the build receives an interrupt or termination signal
- **THEN** `Sources/SafariBrowser/BuildVersion.swift` has its tracked placeholder content again
