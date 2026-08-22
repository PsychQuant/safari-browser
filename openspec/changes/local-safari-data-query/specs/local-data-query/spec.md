## ADDED Requirements

### Requirement: Read-only query commands for local Safari data

The system SHALL provide four top-level subcommands that read Safari's on-disk data files: `history`, `bookmarks`, `cloud-tabs`, and `downloads`. Each command SHALL read exactly one data source and SHALL NOT modify any file it reads.

These commands SHALL NOT require Safari to be running.

| Command | Source file | Content |
|---|---|---|
| `history` | `~/Library/Safari/History.db` | Visited URLs, titles, visit timestamps, visit counts |
| `bookmarks` | `~/Library/Safari/Bookmarks.plist` | Bookmark folder tree and Reading List |
| `cloud-tabs` | `~/Library/Safari/CloudTabs.db` | Tabs open on the user's other iCloud devices |
| `downloads` | `~/Library/Safari/Downloads.plist` | Downloaded filenames and their source URLs |

#### Scenario: History command lists recent visits

- **WHEN** a user runs `safari-browser history --limit 5`
- **THEN** stdout contains at most 5 data rows, each carrying a URL, a title, and a timestamp, ordered most recent first

#### Scenario: Commands do not require Safari to be running

- **WHEN** a user runs `safari-browser bookmarks` while Safari is not running
- **THEN** the command reads `Bookmarks.plist` and prints the bookmark entries without launching Safari

#### Scenario: Source files are never modified

- **WHEN** any of the four commands completes
- **THEN** the modification timestamp and content of the corresponding file under `~/Library/Safari/` are unchanged

---

### Requirement: Safe copy of TCC-protected data files

The system SHALL copy each Safari data file to a temporary location before reading it, rather than opening the file in place. When the source is a SQLite database in WAL mode, the system SHALL also copy the `-wal` and `-shm` sidecar files when they exist.

Reading a WAL-mode database without its sidecar files omits committed data that has not yet been checkpointed, so the sidecar copy is REQUIRED for correctness, not merely for lock avoidance.

The system SHALL remove the temporary copy after the command completes.

#### Scenario: WAL sidecars are copied alongside the database

- **WHEN** the system prepares `History.db` for reading and `History.db-wal` exists
- **THEN** the temporary directory contains both `History.db` and `History.db-wal`

#### Scenario: Recently recorded visits are visible

- **GIVEN** Safari recorded a visit that is present only in the WAL sidecar and not yet checkpointed into the main database
- **WHEN** a user runs `safari-browser history --limit 1`
- **THEN** that visit appears in the output

#### Scenario: Temporary copy is cleaned up

- **WHEN** a command that copied a data file completes, whether successfully or with an error
- **THEN** the temporary directory it created no longer exists

---

### Requirement: Core Data epoch conversion for history timestamps

The system SHALL convert `History.db` visit timestamps from Core Data reference time (seconds since 2001-01-01 UTC) to Unix epoch time by adding 978307200 seconds before formatting them for output.

Omitting this conversion produces timestamps that are silently wrong by approximately 31 years and raises no error, so this conversion SHALL be covered by a unit test that verifies a known input against a known output without depending on live Safari data.

#### Scenario: Core Data reference time converts to the correct calendar date

- **WHEN** the system converts a visit timestamp
- **THEN** the resulting instant equals the Core Data value plus 978307200 seconds interpreted as Unix epoch time

##### Example: Known conversion values

| Core Data value | Unix epoch value | UTC instant |
| --- | --- | --- |
| `0` | `978307200` | 2001-01-01T00:00:00Z |
| `1` | `978307201` | 2001-01-01T00:00:01Z |
| `788918400` | `1767225600` | 2026-01-01T00:00:00Z |

#### Scenario: Output timestamps fall in the current century

- **WHEN** a user runs `safari-browser history --limit 1` on a machine with recent browsing activity
- **THEN** the printed timestamp is within the current century, not the 1990s

---

### Requirement: Full Disk Access failure is distinguished from missing data files

The system SHALL treat "permission denied when reading `~/Library/Safari/`" and "the data file does not exist" as two distinct outcomes.

Permission denial SHALL terminate the command with a non-zero exit code. A missing data file SHALL terminate the command with exit code 0, an empty stdout, and an explanatory line on stderr, because a missing file is a normal configuration state rather than a failure.

#### Scenario: Missing CloudTabs database is not an error

- **GIVEN** `~/Library/Safari/CloudTabs.db` does not exist because the user has not enabled iCloud tab syncing
- **WHEN** a user runs `safari-browser cloud-tabs`
- **THEN** the command exits with code 0, stdout contains no data rows, and stderr explains that the file is absent

#### Scenario: Permission denial exits non-zero

- **GIVEN** the running binary has not been granted Full Disk Access
- **WHEN** a user runs `safari-browser history`
- **THEN** the command exits with a non-zero code and stdout contains no data rows

---

### Requirement: Permission guidance is specific to the binary's signing state

When a command fails due to insufficient Full Disk Access, the system SHALL inspect the signing state of its own binary and emit guidance matching that state.

For an ad-hoc signed binary, the guidance SHALL state that rebuilding the binary can invalidate an existing Full Disk Access grant, and SHALL name both the option of installing a Developer ID signed build and the option of granting Full Disk Access to the terminal application instead.

For a Developer ID signed binary, the guidance SHALL direct the user to add the binary itself to Full Disk Access in System Settings.

Generic guidance that does not distinguish these cases is insufficient, because the two states require different user actions.

#### Scenario: Ad-hoc build names the rebuild caveat

- **GIVEN** the running binary is ad-hoc signed
- **WHEN** a command fails due to insufficient Full Disk Access
- **THEN** stderr states that rebuilding the binary can invalidate the grant, and names both remediation options

#### Scenario: Developer ID build points at the binary

- **GIVEN** the running binary carries a Developer ID signature
- **WHEN** a command fails due to insufficient Full Disk Access
- **THEN** stderr directs the user to add this binary to Full Disk Access in System Settings

---

### Requirement: Default result limits reflect data sensitivity

The system SHALL apply a default result limit of 50 to `history` and `downloads`, which expose long-term records of user behavior, and SHALL NOT impose a default limit on `bookmarks` and `cloud-tabs`, which expose user-curated or currently-open state.

`history` and `downloads` SHALL accept a `--limit` option to override the default. `bookmarks` and `cloud-tabs` SHALL NOT provide a `--limit` option.

The system SHALL NOT gate these commands behind an interactive confirmation prompt, because an interactive prompt would prevent use in a shell pipeline.

#### Scenario: History defaults to 50 rows

- **GIVEN** the history database holds more than 50 visits
- **WHEN** a user runs `safari-browser history` with no `--limit`
- **THEN** stdout contains exactly 50 data rows

#### Scenario: Bookmarks are not truncated

- **GIVEN** the user has more than 50 bookmarks
- **WHEN** a user runs `safari-browser bookmarks`
- **THEN** stdout contains one data row per bookmark with no truncation

#### Scenario: Commands never prompt

- **WHEN** any of the four commands runs with stdin closed
- **THEN** the command completes without waiting for input

---

### Requirement: Filtering options for history and bookmarks

The `history` command SHALL accept `--search <text>` to filter results to entries whose URL or title contains the given text, compared case-insensitively, and SHALL accept `--since <YYYY-MM-DD>` to filter results to visits on or after the given date.

The `bookmarks` command SHALL accept `--folder <name>` to filter results to bookmarks whose containing folder path contains the given name, compared case-insensitively.

When a filter matches nothing, the command SHALL exit with code 0 and produce no data rows.

#### Scenario: Search matches title case-insensitively

- **GIVEN** the history contains an entry titled `Community Benchmarks`
- **WHEN** a user runs `safari-browser history --search benchmarks`
- **THEN** that entry appears in the output

#### Scenario: Empty result set exits successfully

- **WHEN** a user runs `safari-browser history --search zzzzznomatchzzzzz`
- **THEN** the command exits with code 0 and stdout contains no data rows
