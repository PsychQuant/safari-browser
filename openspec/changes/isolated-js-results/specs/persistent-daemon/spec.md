## ADDED Requirements

### Requirement: Ephemeral AppleScript compilation

The daemon SHALL support `applescript.executeEphemeral` with the same source/timing input and status/output/error response shape as `applescript.execute`. It SHALL compile and execute on the main actor without reading or retaining compiled objects in CompileCache. Existing `applescript.execute` calls SHALL retain their reusable-cache behavior. Invocation-owned JavaScript protocol operations SHALL select ephemeral compilation through both in-process and RPC paths. Source logging SHALL retain existing redaction rules.

#### Scenario: Fresh sessions do not accumulate retained scripts
- **GIVEN** one reusable script has been cached
- **WHEN** four fresh result sessions execute their protocol through the production in-process compiler route
- **THEN** the retained cache count SHALL remain one and all results SHALL be correct

#### Scenario: Reusable handles remain reusable
- **WHEN** a reusable script with a persistent counter runs, the same source runs ephemerally, then the reusable script runs again
- **THEN** the outputs SHALL be 1, 1, and 2, and the retained cache count SHALL remain one

#### Scenario: Legacy daemon cannot ignore ephemeral policy
- **WHEN** an older daemon does not implement `applescript.executeEphemeral`
- **THEN** its method-not-found response SHALL permit the existing stateless fallback without executing source on the old daemon
- **AND** an unknown outcome after transmission SHALL NOT permit replay

#### Scenario: Ephemeral errors and logging
- **WHEN** temporary compilation or execution fails
- **THEN** the existing structured error SHALL be returned without adding a permanent cache entry
- **AND** source content SHALL remain redacted in normal daemon logs
