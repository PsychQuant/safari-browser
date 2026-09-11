## ADDED Requirements
### Requirement: Private consistent snapshots
SQLite reads SHALL use a consistent in-memory backup; plist reads SHALL remain in memory. No new safari-data disk copy SHALL be created, including on interruption. Source data content SHALL NOT be written.
#### Scenario: Checkpoint while copying
- **WHEN** another connection checkpoints or appends during backup
- **THEN** the returned snapshot SHALL contain one coherent committed view.
### Requirement: Honest source errors
ENOENT SHALL be absent, EACCES/EPERM SHALL be FDA denial, other I/O failures SHALL remain I/O errors, and malformed data SHALL be parse errors. Diagnostics SHALL identify the source path.
#### Scenario: Disk or read error
- **WHEN** source access fails with EIO
- **THEN** the message SHALL NOT recommend FDA authorization.
### Requirement: Complete bounded query
A query SHALL stop immediately when its requested number of accepted rows is reached. Otherwise SQLite errors SHALL fail and report rows actually stepped.
#### Scenario: Damage beyond limit
- **WHEN** N good rows satisfy the request before a damaged page
- **THEN** the query SHALL return N without stepping into unrelated damage.
### Requirement: Explicit parser coverage
All four parsers SHALL distinguish empty/filter-no-match from schema failure. All-invalid content SHALL fail; partial invalid content SHALL warn with entry location and preserve valid data. Missing optional values SHALL NOT invent facts.
#### Scenario: Required URL renamed
- **WHEN** every nonempty record lacks its required URL/path
- **THEN** the command SHALL report schema failure with nonzero status.
### Requirement: Safe text boundaries
All local-data text fields and dialog diagnostics SHALL escape control characters and structural quotes. Dialog fields SHALL be bounded with explicit truncation; JSON and raw button matching SHALL retain their data.
#### Scenario: Malicious title
- **WHEN** a title contains ESC, CR, quotes or Unicode line separators
- **THEN** it SHALL not create terminal controls, forged rows or warning fields.
### Requirement: Bookmark search
Bookmarks SHALL support case-insensitive title/URL search combined with the folder filter.
#### Scenario: Reading List match
- **WHEN** a Reading List title matches search and folder constraints
- **THEN** the result SHALL retain its Reading List flag in text and JSON.
