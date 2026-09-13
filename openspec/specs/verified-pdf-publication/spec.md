# Verified PDF publication

## Requirements

### Requirement: Private staging and atomic publication
The PDF transaction SHALL export to a unique `.pdf` path in a newly created private directory. It SHALL verify a coherent, complete, readable PDF snapshot with at least one page before publication. It SHALL NOT use an existing destination, a subprocess acknowledgment, or a quiet interval alone as completion evidence. The published inode SHALL be independent of Safari's staging inode.

Publication SHALL use an atomic same-directory replacement or no-replace operation. Without overwrite permission it SHALL fail on any existing destination, including one created after preflight. With permission it SHALL replace the named directory entry rather than writing through a leaf symlink. Directories, links to directories, special files, NUL paths and uninspectable targets SHALL be refused. The transaction SHALL preserve existing regular-file permissions; new files SHALL use the staging file's ordinary permissions. Private temporary artifacts SHALL be cleaned without deleting the published destination.

#### Scenario: Existing valid PDF is not new output
- **WHEN** a valid PDF already exists at the destination and the current staging output is missing or incomplete
- **THEN** the transaction does not report success or replace the destination

#### Scenario: Destination appears after preflight
- **WHEN** a destination appears before publication and overwrite is absent
- **THEN** atomic no-replace fails and preserves that destination

#### Scenario: Published snapshot is independent
- **WHEN** a verified snapshot is published and staging is subsequently modified
- **THEN** the published bytes do not change through the staging inode

### Requirement: Single deadline native script
The exporter and snapshot observation SHALL share a monotonic 60-second default budget. The native subprocess watchdog SHALL use the remaining budget. Menu, navigation and terminal-state polling SHALL not each receive a reset total deadline. Cancellation or expiration SHALL prevent starting publication. An uncertain publication SHALL NOT be retried.

The native script SHALL preserve one invocation, verify the original window ID and URL before menu/key/terminal operations, verify the staging filename before one named Save, and observe sheet closure. Any additional staging confirmation SHALL fail without a default press, Replace press or Return retry. Errors SHALL preserve diagnostics about unresolved native UI and clipboard restoration limits.

#### Scenario: Delayed additional confirmation
- **WHEN** a nested sheet appears after the initial Save, including after 0.5 seconds
- **THEN** terminal polling observes it and refuses it without another confirmation

#### Scenario: Timeout before output is ready
- **WHEN** the shared deadline expires before a complete snapshot can be published
- **THEN** no destination publication begins and the command fails explicitly

### Requirement: Effective path and command integration
The command SHALL expand tilde and relative paths, append `.pdf` when no extension is supplied, and preserve an explicit extension. It SHALL validate directory semantics before extension normalization. Successful output SHALL identify the actual destination using terminal-safe text. The native-export test seam SHALL replace only the native boundary, not bypass snapshot validation and publication.

#### Scenario: Extensionless output
- **WHEN** the user requests `report` as a file destination
- **THEN** successful output is published as `report.pdf` and that actual path is reported

#### Scenario: Explicit non-PDF extension
- **WHEN** the user requests `report.txt`
- **THEN** the verified PDF is published at `report.txt` without a native format-confirmation shortcut
