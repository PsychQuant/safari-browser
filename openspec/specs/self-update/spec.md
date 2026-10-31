# self-update Specification

## Purpose

`self-update` replaces the installed safari-browser binary with the latest GitHub release after verifying it, and `self-update --check` reports whether a newer release exists without changing anything. It exists so an installed Developer ID build can stay current without repeating the manual download-and-verify steps by hand.

## Requirements

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


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Latest release lookup

The command SHALL obtain the latest release from `https://api.github.com/repos/PsychQuant/safari-browser/releases/latest` with a 15-second deadline for the whole request (not only for idle gaps), and SHALL refuse an answer larger than 1 MiB. The response SHALL be accepted only when `tag_name` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`, `draft` and `prerelease` are false, exactly one asset is named `safari-browser`, exactly one asset is named `safari-browser.sha256`, and both download URLs begin with `https://github.com/PsychQuant/safari-browser/releases/download/<tag>/`. `draft` and `prerelease` SHALL be JSON booleans and each asset `size` a JSON integer; a missing or differently typed field SHALL be reported as a malformed answer naming the field. The binary asset SHALL NOT exceed 64 MiB and the checksum asset SHALL NOT exceed 1 KiB, both by declared size and while downloading: a declared length over the limit SHALL be refused before the body is read, and a download SHALL be cancelled as soon as more bytes than the limit have arrived. Any other response SHALL be a lookup failure naming what did not match.

#### Scenario: Asset hosted under another repository

- **WHEN** the release response lists `safari-browser` with a download URL under a different repository
- **THEN** the command SHALL fail without downloading the binary and SHALL name the rejected URL prefix

#### Scenario: Body larger than its limit

- **WHEN** an asset's body keeps arriving past its limit
- **THEN** the download SHALL be cancelled once the received bytes exceed the limit, without waiting for the rest, and the command SHALL fail naming the asset and the limit

#### Scenario: Release asset names match the release script

- **WHEN** the contract test reads `BINARY_NAME` from `scripts/release.sh`
- **THEN** it SHALL equal the binary asset name the command looks for, and the checksum asset name SHALL be that name followed by `.sha256`


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Check reports without writing

`self-update --check` SHALL perform the release lookup and the installed version comparison and SHALL report the result. It SHALL NOT download the binary asset and SHALL NOT create, modify, or delete any file. It SHALL NOT fail because the executable path cannot be resolved, since it does not use it.

#### Scenario: Check with a newer release available

- **WHEN** the installed version is `v2.7.0`, the latest release is `v2.8.0`, and the user runs `safari-browser self-update --check`
- **THEN** the command SHALL print both versions, SHALL exit 0, and the installed binary file SHALL be byte-identical and inode-identical to before


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Check JSON status is a closed enumeration

`self-update --check --json` SHALL print one JSON object with the keys `installed`, `latest`, and `status`. `status` SHALL be exactly one of `up-to-date`, `update-available`, `ahead`, `not-comparable`, `lookup-failed`. When `status` is `lookup-failed`, `latest` SHALL be `null`, an `error` key SHALL hold a single line without control characters, and the exit code SHALL be 1; for every other status the exit code SHALL be 0. `--json` without `--check` SHALL be a usage error.

#### Scenario: Lookup fails while offline

- **WHEN** the release lookup times out and the user runs `safari-browser self-update --check --json`
- **THEN** the command SHALL print `{"installed":"<version>","latest":null,"status":"lookup-failed","error":"<one line>"}` and SHALL exit 1


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Downloaded binary matches its published checksum

The command SHALL compute the SHA-256 of the downloaded binary in memory and compare it with the checksum asset before anything is written to disk. The checksum asset SHALL consist of 64 lowercase hexadecimal characters followed by at most one newline, and the computed digest SHALL equal it. A malformed checksum asset or a mismatch SHALL fail the update. Only then SHALL the binary be written to a staging file created with `mkstemp` (mode 0600) in the same directory as the file being replaced; the staging file SHALL become executable (0755) only after the signature requirement passes.

#### Scenario: Checksum mismatch

- **WHEN** the downloaded binary's SHA-256 differs from the published checksum
- **THEN** the command SHALL exit 1 naming the mismatch, SHALL NOT have written the download to the install directory, and SHALL leave the installed binary unchanged


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: New binary satisfies the installed designated requirement

Before the new binary is executed or installed, the command SHALL require all of the following, using the shared `SignatureAssessment` with required entitlement `com.apple.security.automation.apple-events`: the installed binary assesses as `durable` with shape `Developer ID`; the staged binary assesses as `durable` with shape `Developer ID`; the staged binary's signing flags include hardened runtime; and the staged binary satisfies the installed binary's designated requirement under `SecStaticCodeCheckValidity` with all architectures checked and strict validation (`kSecCSStrictValidate`, what `codesign --verify --strict` adds). No revocation or notarization check is made: neither can be confirmed for a bare Mach-O from the command line, and the manual README steps make neither. An installed binary that is not a Developer ID durable build SHALL make the command refuse and point to the manual install steps in `README.md`.

#### Scenario: Installed build is ad-hoc signed

- **WHEN** the installed binary was produced by `make install` (ad-hoc signed) and the user runs `safari-browser self-update`
- **THEN** the command SHALL exit 1 before downloading the binary asset, stating that there is no Developer ID identity to compare against and naming the manual steps

#### Scenario: Release signed by a different identity

- **WHEN** the staged binary is a Developer ID build that does not satisfy the installed binary's designated requirement
- **THEN** the command SHALL exit 1, SHALL delete the staging file, and SHALL NOT execute the staged binary


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: New binary reports the release tag

After the signature requirement passes, the command SHALL run the staged binary with `--version`. One 10-second deadline SHALL cover both the run and reading its output, which SHALL be read while the program runs; output beyond 4096 bytes SHALL fail the probe. After the program exits, its output SHALL be used once the pipe closes or after a 0.5-second grace, so a background process that keeps the pipe open cannot hold the update. The output with one trailing newline removed SHALL equal the release tag exactly.

#### Scenario: Staged binary reports a different version

- **WHEN** the release tag is `v2.8.0` and the staged binary prints `v2.7.0`
- **THEN** the command SHALL exit 1, SHALL delete the staging file, and SHALL leave the installed binary unchanged


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Atomic replacement keeps a backup

The file replaced SHALL be the installed executable path with symbolic links resolved; a symbolic link pointing to it SHALL remain in place. After every check passes, the command SHALL hard-link the current target to a fresh temporary name, `rename` that over `<target>.previous`, and then `rename` the staging file over the target. An existing `<target>.previous` SHALL therefore be replaced only once the new backup exists, and a failure to place the backup SHALL abort the update before the target changes and leave the old `<target>.previous` in place. At every moment the target path SHALL exist, and a process already running the old binary SHALL keep running.

#### Scenario: Replacement while the old binary is running

- **WHEN** a process is executing the installed binary and the update completes
- **THEN** the target path SHALL hold the new binary with a new inode, `<target>.previous` SHALL hold the old bytes, and the running process SHALL be unaffected


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: One update at a time from the installed binary

Before downloading the binary, the command SHALL take an exclusive, non-blocking `flock` on `.safari-browser.self-update-lock` in the target directory and SHALL hold it until it finishes; when another run holds it, the command SHALL exit 1 saying so. With the lock held, it SHALL confirm that the running code is still valid against its file (`SecCodeCheckValidity`) and that its code hash equals the target file's, and SHALL refuse when either fails, because a run started from a binary that another update has since replaced would otherwise turn `<target>.previous` into a copy of the new version.

#### Scenario: A second run while one is in progress

- **WHEN** a run holds the lock and another `safari-browser self-update` starts in the same install directory
- **THEN** the second SHALL exit 1 without downloading the binary and without touching the target or `<target>.previous`

#### Scenario: Run from a binary that was replaced meanwhile

- **WHEN** the target was replaced by another update after this process started
- **THEN** the command SHALL exit 1 asking to run `self-update` again, leaving `<target>.previous` unchanged


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Interrupted runs leave nothing behind for long

A run that is killed (signal, crash, power loss) cannot remove its own staging file. Every run that takes the lock SHALL, after the running-binary check and before any download, remove the regular files owned by the user in the target directory whose names are `.safari-browser.self-update.` or `.safari-browser.self-update-prev.` followed by exactly six ASCII letters or digits, and SHALL leave every other entry alone. The target path SHALL exist at every moment of a replacement.

#### Scenario: Leftover from an interrupted run

- **WHEN** `.safari-browser.self-update.AbC123` remains in `~/bin` from a run killed during its version probe
- **THEN** the next `self-update` that takes the lock SHALL remove it and SHALL keep `notes.txt`, `.safari-browser.self-update-lock`, and any directory with a staging-shaped name


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Failure leaves the installed binary unchanged

On any failure — network, response shape, size limit, checksum, signature, version, write permission, or backup — the command SHALL exit 1 with a message naming the failed step, SHALL delete its staging file, and SHALL leave the target path's bytes and inode unchanged. The command SHALL NOT invoke `sudo` or request elevated privileges.

#### Scenario: Target directory is not writable

- **WHEN** the installed binary lives in a directory the user cannot write
- **THEN** the command SHALL exit 1 stating the directory is not writable, without prompting for a password


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Running daemons are stopped after replacement

After a successful replacement, the command SHALL enumerate `safari-browser-<name>.sock` entries in the default daemon socket directory and, for each daemon that is alive, SHALL send `daemon.shutdown` and wait up to 5 seconds as `daemon stop` does. It SHALL print `daemon <name>: stopped` for each stopped daemon and then print `safari-browser daemon start`, with `--name <name>` (shell-quoted unless it consists only of ASCII letters, digits and `._-/`) for namespaces other than `default`. A daemon left running keeps running the old binary (and, before #304 made the handshake carry the build identity, also kept answering the new CLI with the old code): a daemon that does not stop SHALL produce a warning saying so, the output SHALL name the directory that was searched and say that a daemon started elsewhere is not found, and when the socket directory cannot be resolved the command SHALL warn that no daemon was stopped. None of these SHALL change the exit code from 0. The output SHALL also say that a running `safari-browser mcp` server refuses tool calls until it is restarted.

#### Scenario: Default daemon running during update

- **WHEN** the `default` daemon is running and the update completes
- **THEN** the command SHALL stop it, print `daemon default: stopped`, print `safari-browser daemon start`, name the searched directory, mention running MCP servers, and exit 0


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: No prompt before replacing

`self-update` SHALL NOT ask for confirmation before replacing the installed binary. Previewing is `self-update --check`. When the installed build is `up-to-date` or `ahead`, the command SHALL print the reason and exit 0 without downloading the binary; when it is `not-comparable`, the command SHALL exit 1 and point to the manual install steps.

#### Scenario: Already up to date

- **WHEN** the installed version equals the latest release tag with no suffix and the user runs `safari-browser self-update`
- **THEN** the command SHALL print that it is up to date, SHALL NOT download the binary asset, and SHALL exit 0


<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->

---
### Requirement: Self-update is not an MCP tool

`self-update` SHALL NOT appear in the MCP tool catalog that `safari-browser mcp` serves. It replaces the binary an MCP server runs from and is meant for the person at the terminal, not for an MCP client; the catalog SHALL exclude the `self-update` command the same way it excludes `mcp`.

#### Scenario: MCP catalog lists no self-update tool

- **WHEN** the MCP tool catalog is built from the CLI's command metadata
- **THEN** no tool's path SHALL begin with `self-update`

<!-- @trace
source: add-self-update-command
updated: 2026-10-31
code:
  - openspec
  - .spectra.yaml
-->
