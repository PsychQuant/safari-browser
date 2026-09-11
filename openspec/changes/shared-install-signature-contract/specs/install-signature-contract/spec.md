## ADDED Requirements

### Requirement: Shared signature assessment
The runtime and standalone guard SHALL consume one Security-framework-based assessment. Path text SHALL NOT affect classification. Existing guard status codes and the order of unsigned, broken seal, ad-hoc, entitlement, DR shape and satisfaction checks SHALL be preserved.
#### Scenario: Misleading path
- **WHEN** identical unsigned bytes are placed under a path containing Authority=Developer ID Application
- **THEN** runtime and guard SHALL both refuse to classify the signature as durable.

### Requirement: Durable guidance
The FDA guidance SHALL route to install-signed and explain that rebuild durability depends on retaining the same signing identity and designated requirement. Ad-hoc guidance SHALL retain the rebuild caveat.
#### Scenario: Rebuild with changed identity
- **WHEN** a signed build uses a different identity or designated requirement
- **THEN** guidance SHALL NOT promise the old FDA grant survives.

### Requirement: Atomic installation evidence
Both install modes SHALL stage before replacing the destination and SHALL retain the old binary when signing or pre-install verification fails. A running holder of the old inode SHALL NOT force the new installed binary to use that inode.
#### Scenario: Running old binary
- **WHEN** an install replaces a fixture still held open by a running process
- **THEN** the new path SHALL have a fresh inode, run successfully, and leave the old process intact.

### Requirement: Maintained signing entrypoints
The current Makefile and in-flight specifications SHALL use install-signed as the signed installation path; the uninstalled sign-developer-id target SHALL be removed with migration documentation. Shared-source builds SHALL preserve all declared mutation tests.
#### Scenario: Shared policy regression
- **WHEN** any declared fix is removed from either the shared assessment or CLI wrapper
- **THEN** the mutation gate SHALL fail a named assertion, and malformed or unbuildable mutants SHALL remain gate errors.
