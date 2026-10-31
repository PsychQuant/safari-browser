## ADDED Requirements

### Requirement: Self-update uses the shared assessment and atomic installation

`self-update` SHALL classify both the installed and the staged binary with the shared Security-framework-based `SignatureAssessment`, and SHALL NOT parse human-readable `codesign` output. Like both install modes, it SHALL stage before replacing the destination, SHALL retain the old binary when verification fails, and SHALL give the destination a fresh inode without disturbing a running holder of the old inode.

#### Scenario: Staged binary fails verification

- **WHEN** the staged binary fails the signature requirement during `self-update`
- **THEN** the destination SHALL keep the old binary's bytes and inode, and no staging file SHALL remain in its directory
