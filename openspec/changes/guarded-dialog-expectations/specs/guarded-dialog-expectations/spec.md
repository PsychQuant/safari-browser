## ADDED Requirements

### Requirement: Caller-bound dialog expectation
Dialog dismissal SHALL accept optional paired expected window ID and raw message values. Invalid pairs or non-positive IDs SHALL fail validation. A message mismatch SHALL refuse before selecting or pressing a button. The expected window ID SHALL be checked on the complete, unique snapshot used at the actual press boundary, before decision or press callbacks. Existing ordered button/message fingerprint, permission, session and deadline guards SHALL remain authoritative. Without expectations, existing named-button behavior SHALL remain unchanged.

#### Scenario: Replaced before command begins
- **WHEN** the caller verified fixture window 71 and message "nonce", but the command observes a different message or window 72 with identical text and buttons
- **THEN** no button is pressed and a refusal is returned

#### Scenario: Expected fixture remains
- **WHEN** window 71, raw message "nonce" and the observed ordered button fingerprint still match at the guarded boundary
- **THEN** the named button may be pressed after the existing guards pass

#### Scenario: Invalid expectation
- **WHEN** only one expectation flag is supplied, or window ID is zero or negative
- **THEN** validation rejects the command before dialog inspection

### Requirement: Fixture handoff
The background-dialog harness SHALL pass its verified nonce message and stable window ID into the actual dismissal operation. A separate preflight alone SHALL NOT authorize the press. Live GUI acceptance SHALL remain pending while the session is locked.

#### Scenario: Handoff replacement
- **WHEN** a user dialog replaces the fixture after the harness's last observation
- **THEN** the transmitted expectation prevents that dialog from receiving a press
