## Purpose

`self-update` replaces the installed safari-browser binary with the latest GitHub release after verifying it, and `self-update --check` reports whether a newer release exists without changing anything. It exists so an installed Developer ID build can stay current without repeating the manual download-and-verify steps by hand.

## ADDED Requirements

### Requirement: Installed version comparison

The command SHALL classify the installed build against the latest release tag `vA.B.C` using the installed version string from `BuildVersion`. A version string matching `v<major>.<minor>.<patch>`, optionally followed by `-<n>-g<hex>` and optionally by `-dirty`, SHALL be comparable on its three numeric components; any other string, including a bare commit hash and `unknown`, SHALL be classified as `not-comparable`. A comparable build SHALL be `update-available` when the latest tag is greater, `up-to-date` when the latest tag is equal and the build has no suffix, and `ahead` when the latest tag is equal and the build has a suffix or when the latest tag is smaller.

#### Scenario: Development build on the latest tag is not replaced

- **WHEN** the installed version is `v2.8.0-3-gabc1234` and the latest release tag is `v2.8.0`
- **THEN** the classification SHALL be `ahead`

##### Example: classification table

| Installed | Latest | Classification |
| --- | --- | --- |
| `v2.7.0` | `v2.8.0` | `update-available` |
| `v2.8.0` | `v2.8.0` | `up-to-date` |
| `v2.8.0-dirty` | `v2.8.0` | `ahead` |
| `v2.7.0-5-g1a2b3c4` | `v2.8.0` | `update-available` |
| `v2.9.0` | `v2.8.0` | `ahead` |
| `1a2b3c4` | `v2.8.0` | `not-comparable` |
| `unknown` | `v2.8.0` | `not-comparable` |

### Requirement: Latest release lookup

The command SHALL obtain the latest release from `https://api.github.com/repos/PsychQuant/safari-browser/releases/latest` with a 15-second timeout. The response SHALL be accepted only when `tag_name` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`, `draft` and `prerelease` are false, exactly one asset is named `safari-browser`, exactly one asset is named `safari-browser.sha256`, and both download URLs begin with `https://github.com/PsychQuant/safari-browser/releases/download/<tag>/`. The binary asset SHALL NOT exceed 64 MiB and the checksum asset SHALL NOT exceed 1 KiB. Any other response SHALL be a lookup failure naming what did not match.

#### Scenario: Asset hosted under another repository

- **WHEN** the release response lists `safari-browser` with a download URL under a different repository
- **THEN** the command SHALL fail without downloading the binary and SHALL name the rejected URL prefix

#### Scenario: Release asset names match the release script

- **WHEN** the contract test reads `BINARY_NAME` from `scripts/release.sh`
- **THEN** it SHALL equal the binary asset name the command looks for, and the checksum asset name SHALL be that name followed by `.sha256`

### Requirement: Check reports without writing

`self-update --check` SHALL perform the release lookup and the installed version comparison and SHALL report the result. It SHALL NOT download the binary asset and SHALL NOT create, modify, or delete any file.

#### Scenario: Check with a newer release available

- **WHEN** the installed version is `v2.7.0`, the latest release is `v2.8.0`, and the user runs `safari-browser self-update --check`
- **THEN** the command SHALL print both versions, SHALL exit 0, and the installed binary file SHALL be byte-identical and inode-identical to before

### Requirement: Check JSON status is a closed enumeration

`self-update --check --json` SHALL print one JSON object with the keys `installed`, `latest`, and `status`. `status` SHALL be exactly one of `up-to-date`, `update-available`, `ahead`, `not-comparable`, `lookup-failed`. When `status` is `lookup-failed`, `latest` SHALL be `null`, an `error` key SHALL hold a single line without control characters, and the exit code SHALL be 1; for every other status the exit code SHALL be 0. `--json` without `--check` SHALL be a usage error.

#### Scenario: Lookup fails while offline

- **WHEN** the release lookup times out and the user runs `safari-browser self-update --check --json`
- **THEN** the command SHALL print `{"installed":"<version>","latest":null,"status":"lookup-failed","error":"<one line>"}` and SHALL exit 1

### Requirement: Downloaded binary matches its published checksum

The command SHALL download the binary asset into a staging file created with `mkstemp` in the same directory as the file being replaced, and SHALL compute its SHA-256. The checksum asset SHALL consist of 64 lowercase hexadecimal characters followed by at most one newline, and the computed digest SHALL equal it. A malformed checksum asset or a mismatch SHALL fail the update.

#### Scenario: Checksum mismatch

- **WHEN** the downloaded binary's SHA-256 differs from the published checksum
- **THEN** the command SHALL exit 1 naming the mismatch, SHALL delete the staging file, and SHALL leave the installed binary unchanged

### Requirement: New binary satisfies the installed designated requirement

Before the new binary is executed or installed, the command SHALL require all of the following, using the shared `SignatureAssessment` with required entitlement `com.apple.security.automation.apple-events`: the installed binary assesses as `durable` with shape `Developer ID`; the staged binary assesses as `durable` with shape `Developer ID`; the staged binary's signing flags include hardened runtime; and the staged binary satisfies the installed binary's designated requirement under `SecStaticCodeCheckValidity` with all architectures checked. An installed binary that is not a Developer ID durable build SHALL make the command refuse and point to the manual install steps in `README.md`.

#### Scenario: Installed build is ad-hoc signed

- **WHEN** the installed binary was produced by `make install` (ad-hoc signed) and the user runs `safari-browser self-update`
- **THEN** the command SHALL exit 1 before downloading the binary asset, stating that there is no Developer ID identity to compare against and naming the manual steps

#### Scenario: Release signed by a different identity

- **WHEN** the staged binary is a Developer ID build that does not satisfy the installed binary's designated requirement
- **THEN** the command SHALL exit 1, SHALL delete the staging file, and SHALL NOT execute the staged binary

### Requirement: New binary reports the release tag

After the signature requirement passes, the command SHALL run the staged binary with `--version` under a 10-second timeout, and its standard output with one trailing newline removed SHALL equal the release tag exactly.

#### Scenario: Staged binary reports a different version

- **WHEN** the release tag is `v2.8.0` and the staged binary prints `v2.7.0`
- **THEN** the command SHALL exit 1, SHALL delete the staging file, and SHALL leave the installed binary unchanged

### Requirement: Atomic replacement keeps a backup

The file replaced SHALL be the installed executable path with symbolic links resolved; a symbolic link pointing to it SHALL remain in place. After every check passes, the command SHALL remove any existing `<target>.previous`, hard-link the current target to `<target>.previous`, and then `rename` the staging file over the target. A failure to create the backup SHALL abort the update before the target changes. At every moment the target path SHALL exist, and a process already running the old binary SHALL keep running.

#### Scenario: Replacement while the old binary is running

- **WHEN** a process is executing the installed binary and the update completes
- **THEN** the target path SHALL hold the new binary with a new inode, `<target>.previous` SHALL hold the old bytes, and the running process SHALL be unaffected

### Requirement: Failure leaves the installed binary unchanged

On any failure — network, response shape, size limit, checksum, signature, version, write permission, or backup — the command SHALL exit 1 with a message naming the failed step, SHALL delete its staging file, and SHALL leave the target path's bytes and inode unchanged. The command SHALL NOT invoke `sudo` or request elevated privileges.

#### Scenario: Target directory is not writable

- **WHEN** the installed binary lives in a directory the user cannot write
- **THEN** the command SHALL exit 1 stating the directory is not writable, without prompting for a password

### Requirement: Running daemons are stopped after replacement

After a successful replacement, the command SHALL enumerate `safari-browser-<name>.sock` entries in the default daemon socket directory and, for each daemon that is alive, SHALL send `daemon.shutdown` and wait up to 5 seconds as `daemon stop` does. It SHALL print `daemon <name>: stopped` for each stopped daemon and then print `safari-browser daemon start`, with `--name <name>` for namespaces other than `default`. A daemon that does not stop SHALL produce a warning and SHALL NOT change the exit code from 0.

#### Scenario: Default daemon running during update

- **WHEN** the `default` daemon is running and the update completes
- **THEN** the command SHALL stop it, print `daemon default: stopped`, print `safari-browser daemon start`, and exit 0

### Requirement: No prompt before replacing

`self-update` SHALL NOT ask for confirmation before replacing the installed binary. Previewing is `self-update --check`. When the installed build is `up-to-date` or `ahead`, the command SHALL print the reason and exit 0 without downloading the binary; when it is `not-comparable`, the command SHALL exit 1 and point to the manual install steps.

#### Scenario: Already up to date

- **WHEN** the installed version equals the latest release tag with no suffix and the user runs `safari-browser self-update`
- **THEN** the command SHALL print that it is up to date, SHALL NOT download the binary asset, and SHALL exit 0
