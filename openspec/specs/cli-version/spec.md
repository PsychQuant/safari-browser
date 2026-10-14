# cli-version Specification

## Purpose

Let a user or a script ask an installed safari-browser binary which build it is, and map the answer back to a git tag or commit.

## Requirements

### Requirement: The CLI reports a version

The system SHALL accept `--version` on the root command, print a single version string to standard output, and exit with status 0. The string SHALL be taken from one constant, `BuildVersion.value`, so no other part of the program carries its own copy.

#### Scenario: Print the version

- **WHEN** the user runs `safari-browser --version`
- **THEN** the program prints the value of `BuildVersion.value` followed by a newline and exits with status 0

#### Scenario: A build that was not stamped

- **WHEN** the binary was built without the Makefile stamping step, for example by running `swift build` directly
- **THEN** `safari-browser --version` prints `unknown`

### Requirement: The version maps to a git tag or commit

A stamped build SHALL carry the output of `git describe --tags --match 'v[0-9]*' --always --dirty` taken from the repository the binary was built from. Only tags that start with `v` followed by a digit SHALL be used as the base, so IDD baseline tags never appear in the string.

#### Scenario: Built exactly on a release tag

- **GIVEN** `HEAD` is the commit tagged `v2.6.0` and the working tree is clean
- **WHEN** the binary is built with `make build`
- **THEN** `safari-browser --version` prints `v2.6.0`

#### Scenario: Built after a release

- **GIVEN** `HEAD` is 31 commits after `v2.6.0` at abbreviated commit `d454d7c` and the working tree is clean
- **WHEN** the binary is built with `make build`
- **THEN** `safari-browser --version` prints `v2.6.0-31-gd454d7c`

#### Scenario: Built with uncommitted changes

- **GIVEN** the working tree has uncommitted changes to tracked files
- **WHEN** the binary is built with `make build`
- **THEN** the printed version ends with `-dirty`

#### Scenario: Baseline tags are ignored

- **GIVEN** the nearest tag reachable from `HEAD` is `idd-217-baseline` and an older tag `v2.6.0` is also reachable
- **WHEN** the binary is built with `make build`
- **THEN** the printed version starts with `v2.6.0`, not `idd-217-baseline`

### Requirement: A version that cannot be determined is reported as unknown

When the repository has no `.git`, when `git` is unavailable, or when `git describe` fails, the stamped value SHALL be `unknown` and the build SHALL still succeed. A version string that contains characters outside letters, digits, `.`, `_`, `+` and `-` SHALL be replaced by `unknown` rather than written into the source file.

#### Scenario: Build from a source archive

- **GIVEN** the source tree has no `.git` directory
- **WHEN** the binary is built with `make build`
- **THEN** the build succeeds and `safari-browser --version` prints `unknown`

#### Scenario: A string that would break the Swift literal

- **GIVEN** the computed version contains a double quote
- **WHEN** the stamping step runs
- **THEN** it writes `unknown` instead and the build still succeeds

### Requirement: The reported version is the client binary's

`--version` SHALL report the version of the binary that executes it. It SHALL NOT contact the persistent daemon and SHALL NOT report the daemon's version.

#### Scenario: Daemon started before an install

- **GIVEN** a daemon started from a binary installed before the most recent `make install`
- **WHEN** the user runs `safari-browser --version`
- **THEN** the output is the version of the newly installed binary, and no daemon request is made
