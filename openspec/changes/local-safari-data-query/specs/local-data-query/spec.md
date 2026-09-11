## ADDED Requirements

### Requirement: Read-only query commands for local Safari data

The system SHALL provide four top-level subcommands that read Safari's on-disk data files: `history`, `bookmarks`, `cloud-tabs`, and `downloads`. Each command SHALL read exactly one data source and SHALL NOT write source data content. SQLite read connections MAY participate in normal locking and WAL shared-index maintenance; this does not authorize source write SQL.

These commands SHALL NOT require Safari to be running.

| Command | Source file | Content |
|---|---|---|
| `history` | `~/Library/Safari/History.db` | Visited URLs, titles, visit timestamps, visit counts |
| `bookmarks` | `~/Library/Safari/Bookmarks.plist` | Bookmark folder tree and Reading List |
| `cloud-tabs` | `~/Library/Safari/CloudTabs.db` | Tabs open on the user's other iCloud devices |
| `downloads` | `~/Library/Safari/Downloads.plist` | Downloaded filenames and their source URLs |

#### Scenario: History command lists recent visits

- **WHEN** a user runs `safari-browser history --limit 5`
- **THEN** stdout contains at most 5 data rows, each carrying a required URL and optional title/timestamp, ordered most recent first

#### Scenario: Commands do not require Safari to be running

- **WHEN** a user runs `safari-browser bookmarks` while Safari is not running
- **THEN** the command reads `Bookmarks.plist` and prints the bookmark entries without launching Safari

#### Scenario: Source data content is never written

- **WHEN** any of the four commands runs
- **THEN** it performs no source write SQL or source data writes; changes by Safari or normal SQLite shared-index maintenance SHALL NOT be described as application data writes by this tool

---

### Requirement: Private consistent in-memory snapshots

The system SHALL open each SQLite source read-only, establish a consistent read transaction, and use SQLite Backup API to obtain an in-memory snapshot containing committed WAL content. It SHALL read plist sources directly into memory. It SHALL NOT create new disk copies of Safari data or WAL sidecars; SQLite destination temporary storage SHALL remain in memory.

The snapshot operation SHALL have a finite monotonic deadline and report busy, timeout, memory, or I/O failures honestly. Connection lifetime SHALL be scoped to the operation. Existing legacy temporary copies SHALL NOT be swept merely by matching a filename prefix.

This requirement supersedes the #109 sequential main/WAL/SHM copy contract. File permissions alone do not isolate copies from other processes under the same UID, and sequential copying does not establish a consistent SQLite snapshot.

#### Scenario: Recently recorded visits are visible

- **GIVEN** Safari recorded a committed visit present only in WAL and not yet checkpointed into the main database
- **WHEN** a user runs `safari-browser history --limit 1`
- **THEN** the snapshot can return that visit according to the request's ordering and filters

#### Scenario: Concurrent checkpoint yields one committed view

- **WHEN** another SQLite connection writes or checkpoints during backup
- **THEN** a successful snapshot contains one coherent committed view rather than a mixture of separately copied files

#### Scenario: Interruptions leave no new data disk copy

- **WHEN** a command completes, fails, or is interrupted
- **THEN** no new Safari data disk copy or sidecar copy from this operation remains, because none was created

---

### Requirement: Core Data epoch conversion for history timestamps

The system SHALL preserve absent or invalid optional visit timestamps as unknown rather than inventing a date. For present valid timestamps, the system SHALL convert `History.db` visit timestamps from Core Data reference time (seconds since 2001-01-01 UTC) to Unix epoch time by adding 978307200 seconds before formatting them for output.

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

Permission denial SHALL terminate the command with a non-zero exit code. A missing data file (ENOENT) SHALL terminate the command with exit code 0, no text data rows (`[]` on stdout in JSON mode), and an explanation on stderr, because a missing file is a normal configuration state rather than a failure. Only EACCES or EPERM from source access SHALL be mapped to permission denial; other I/O failures SHALL produce a nonzero source-specific I/O error without FDA advice.

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

For an ad-hoc signed binary, the guidance SHALL state that rebuilding the binary can invalidate an existing Full Disk Access grant, and SHALL name both `DEVELOPER_ID=<cert-sha1> make install-signed` for installing a Developer ID signed build and the option of granting Full Disk Access to the terminal application instead.

For a binary verified to have a valid signature and a satisfied, recognized identity-bound designated requirement, the guidance SHALL direct the user to add the binary itself to Full Disk Access in System Settings. It SHALL state that retaining the grant across rebuilds depends on keeping the same signing identity and designated requirement.

When durability cannot be established, guidance SHALL acknowledge the unknown state and name `make verify-install-signature` and `DEVELOPER_ID=<cert-sha1> make install-signed`; it SHALL NOT promise grant persistence based on path text or a Developer ID label alone. The default `make install` SHALL remain ad-hoc and require no Developer ID certificate. This guidance was synchronized in #124 with the #119 installation path and #122 assessment contract; the original #109 default-install decision is retained.

Generic guidance that does not distinguish these cases is insufficient, because these states require different user actions.

#### Scenario: Ad-hoc build names the rebuild caveat

- **GIVEN** the running binary is ad-hoc signed
- **WHEN** a command fails due to insufficient Full Disk Access
- **THEN** stderr states that rebuilding the binary can invalidate the grant, and names both remediation options

#### Scenario: Verified durable build points at the binary

- **GIVEN** the running binary has a verified durable signature
- **WHEN** a command fails due to insufficient Full Disk Access
- **THEN** stderr directs the user to add this binary to Full Disk Access in System Settings, with the condition that the signing identity and designated requirement remain unchanged

#### Scenario: Unknown signature does not promise grant persistence

- **GIVEN** the running binary cannot be verified as durable
- **WHEN** a command fails due to insufficient Full Disk Access
- **THEN** stderr states that durability cannot be confirmed and provides the verification and signed-install commands

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

The `bookmarks` command SHALL accept `--folder <name>` to filter results to bookmarks whose containing folder path contains the given name, compared case-insensitively. It SHALL also accept `--search <text>` for case-insensitive title or URL substring matching using the same Swift Unicode comparison behavior as history. When both options are supplied, both conditions SHALL match. Folder names SHALL NOT be search fields; Reading List flags SHALL be preserved. This requirement does not add search flags to cloud-tabs or downloads.

When a filter matches nothing, the command SHALL exit with code 0 and produce no data rows.

#### Scenario: Search matches title case-insensitively

- **GIVEN** the history contains an entry titled `Community Benchmarks`
- **WHEN** a user runs `safari-browser history --search benchmarks`
- **THEN** that entry appears in the output

#### Scenario: Empty result set exits successfully

- **WHEN** a user runs `safari-browser history --search zzzzznomatchzzzzz`
- **THEN** the command exits with code 0 and stdout contains no data rows


#### Scenario: Bookmark search and folder filters compose

- **GIVEN** a Reading List bookmark has title `ÉCOLE` and a matching containing folder
- **WHEN** the user searches for `école` with that folder filter
- **THEN** the entry appears with its Reading List flag in both text and JSON output; a match only in the folder name SHALL NOT satisfy the search

---

### Requirement: Explicit parser validity and optional data

The required nonempty string fields SHALL be history/cloud-tabs URL, bookmark leaf `URLString`, and download `DownloadEntryPath`. Parsers SHALL distinguish empty data or valid filtered-out records from malformed records. If nonempty examined candidates contain no valid record, schema failure SHALL terminate nonzero with the source, entry location, and field. If valid records coexist with malformed records, valid matching rows SHALL remain available and stderr SHALL warn with the malformed count and entry locations/fields; detailed locations MAY be capped at eight.

Optional fields SHALL NOT be fabricated. History title, visit time, and visit count SHALL support JSON null; download date SHALL support JSON null and sort last with stable ties. A usable history/download date SHALL have finite Unix seconds within `[-62135596800, 253402300800)` and a Gregorian era of 1 with year 1 through 9999 in the current time zone. A date outside either bound SHALL become null/no-date rather than empty formatted text, a clipped year, or an invented date. Other absent optional fields SHALL preserve their explicit empty-string or unknown-device representation. Bookmarks SHALL descend untyped containers, preserve Reading List identification, ignore recognized Safari proxy nodes, and diagnose malformed children independently of valid siblings. An explicit `WebBookmarkTypeList` with no `Children` key SHALL be treated as an empty folder; a present wrong-typed `Children` value SHALL remain malformed.

SQLite diagnostics apply to candidates selected by SQL filters and actually examined before the accepted-result stopping condition. Parsers SHALL NOT perform an extra full scan merely to count unseen malformed records. Valid rows discarded by a Swift search filter SHALL still count as valid for schema assessment.

#### Scenario: All required URLs are missing

- **GIVEN** all examined nonempty records lack their required URL field
- **WHEN** the corresponding command runs
- **THEN** it fails with a schema diagnostic rather than reporting empty success

#### Scenario: Mixed content preserves valid rows

- **GIVEN** a source has one valid record and one malformed record
- **WHEN** it is parsed
- **THEN** the valid matching record remains on stdout and stderr identifies one malformed record with its location and field

#### Scenario: Optional history values are absent

- **WHEN** a valid URL has no usable visit time or count
- **THEN** JSON reports null for those values and text reports no date without inventing an epoch or count

---

#### Scenario: Empty bookmark folder omits its children key

- **GIVEN** a node declares `WebBookmarkTypeList` and has no `Children` key
- **WHEN** bookmarks parses that node
- **THEN** it produces neither a bookmark nor a malformed-entry warning; neighboring valid bookmarks remain available

#### Scenario: Finite extreme dates cannot masquerade as normal dates

- **WHEN** a valid record carries a date such as Unix seconds `1e20`, a BCE instant, or a value overflowing the local Gregorian year range
- **THEN** text reports no date and JSON reports null while retaining the valid URL/path

---

### Requirement: Complete bounded history queries

History SHALL stop SQLite stepping immediately after collecting its requested number of accepted rows. A malformed raw row or a Swift search miss SHALL NOT consume the output limit. The since boundary SHALL use a bound SQL value; raw-row SQL LIMIT SHALL NOT replace the accepted-result limit. When the requested accepted count has not been met, SQLite step failure SHALL fail the command with the actual number of rows stepped rather than silently returning incomplete results.

This boundary does not promise that SQLite's query plan avoids internal sorting or page reads before returning its first row; an appropriate index determines that cost.

#### Scenario: Invalid row does not consume the limit

- **GIVEN** an invalid row precedes a valid matching row
- **WHEN** history runs with limit 1
- **THEN** it returns the valid row, warns about the invalid row, and does not step again after that accepted result

#### Scenario: Valid search misses are not schema errors

- **WHEN** valid examined rows do not match the requested search
- **THEN** the command succeeds with no data rows; any separately malformed examined records produce a warning, not an all-invalid failure

---

### Requirement: Local data command stream and exit contract

All four command bodies SHALL be testable with an injected source URL while production entry points retain their configured Safari source paths. Data rows and JSON SHALL go to stdout; legends, missing-source notices, partial-schema warnings, and error diagnostics SHALL go to stderr. Tests SHALL exercise actual command bodies and derive failures through ArgumentParser exit-code mapping, covering missing sources, permission denial, malformed sources, and mixed data. JSON output SHALL remain valid when stderr carries warnings.

#### Scenario: JSON data and warnings remain separate

- **WHEN** a JSON query succeeds with some malformed entries skipped
- **THEN** stdout contains only a valid JSON array, stderr contains the warning, and exit status is zero
