## MODIFIED Requirements

### Requirement: Export page as PDF
The PDF command SHALL export through one native script to a unique private staging `.pdf` path, using the same shared navigation generator as upload. It SHALL use clipboard path entry with restoration, named enabled initial confirmation without Return fallback, and polling under one shared deadline. Upload's default navigation behavior SHALL remain unchanged.

The command SHALL observe native sheet closure and verify a complete independent PDF snapshot before atomically publishing to the effective destination. No extension SHALL resolve to `.pdf`; an explicit extension SHALL be preserved. Success SHALL identify the actual published path, not merely indicate that Save was dispatched.

Replacement of a destination entry SHALL require `--overwrite` in addition to `--allow-hid`. Existing unauthorized destinations SHALL fail before GUI interaction; late unauthorized destinations SHALL fail through atomic no-replace. Authorized publication SHALL replace the entry without following a leaf symlink; directory and special-file targets SHALL be refused. A staging replacement or other additional native confirmation SHALL always be refused, even when final-destination overwrite is authorized.

The runner SHALL retain bounded escaped action traces after the subprocess completes, including failure and timeout, and SHALL retain the pre-GUI keyboard-control warning. It SHALL NOT replay a dispatched Save, native confirmation or uncertain publication.

#### Scenario: PDF export uses clipboard for path
- **WHEN** the user authorizes PDF export
- **THEN** the staging path is pasted through the shared navigation generator with clipboard restoration

#### Scenario: PDF export uses precise waits
- **WHEN** native dialog transitions or output creation are delayed
- **THEN** they are observed under the common deadline without a fixed one-shot completion assumption

#### Scenario: Existing destination without authorization
- **WHEN** the effective destination exists and overwrite is absent
- **THEN** the command refuses before GUI interaction

#### Scenario: Destination appears after preflight
- **WHEN** the effective destination is created after preflight and overwrite is absent
- **THEN** publication refuses atomically without changing that entry

#### Scenario: Authorized replacement
- **WHEN** allow-hid and overwrite are supplied and a complete snapshot is ready
- **THEN** the command atomically replaces the validated destination entry
- **AND** Safari does not write directly to the published inode
