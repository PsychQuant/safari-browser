## ADDED Requirements

### Requirement: Confirmation traces
File-dialog execution SHALL relay captured stderr on success, failure and timeout without changing stdout or the original error classification. It SHALL drain both pipes concurrently. Relayed traces SHALL escape terminal controls, have a 4096-rendered-scalar bound and explicitly mark truncation. Non-file callers SHALL remain silent unless a writer is requested.

#### Scenario: Successful logged action
- **WHEN** a file-dialog subprocess logs a named confirmation and returns output
- **THEN** the caller receives both the safe stderr trace and the unchanged stdout

### Requirement: No replay after dispatch
Initial file confirmation SHALL use one enabled named Open/Upload/Save button, including the supported Traditional Chinese labels, from the sheet or its split groups. Frontmost and non-nested sheet checks SHALL precede confirmation. Lookup, ambiguity, disabled-state, and dispatched-click errors SHALL NOT cause a Return fallback or retry.

#### Scenario: Uncertain press
- **WHEN** click has been dispatched and reports an error
- **THEN** the error is propagated and no additional Return is sent

### Requirement: Explicit PDF overwrite
PDF replacement SHALL require --overwrite in addition to --allow-hid. An existing destination without overwrite permission SHALL be rejected before GUI operations. Replacement appearing after that check SHALL also be refused without permission. Authorized replacement SHALL use a unique named Replace or 取代 button and SHALL NOT fall back to Return.

#### Scenario: Destination appears after preflight
- **WHEN** a replacement sheet appears and --overwrite was not supplied
- **THEN** no replacement confirmation is dispatched

### Requirement: Native confirmation exception
The non-interference specification SHALL name initial confirmation as part of an authorized native file operation, and SHALL distinguish separate overwrite authorization. Unmeasured Save-panel AX equivalence SHALL remain untested until an owned real GUI fixture establishes the result.

#### Scenario: Evidence boundary
- **WHEN** only construction and subprocess tests have passed
- **THEN** the operation inventory does not claim proven Save-panel AX equivalence
