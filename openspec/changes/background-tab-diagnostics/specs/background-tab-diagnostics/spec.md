## ADDED Requirements

### Requirement: Background target hint after failure
After a typed process timeout or an empty get-text result on a fixed tab target, the system SHALL retain the existing visible-dialog check and MAY emit a background-target hint only after a fresh bounded query confirms the resolved target is not its window's current tab. The hint SHALL NOT assert that a pending dialog exists. The original timeout error and the successful-empty-text behavior SHALL remain unchanged when no visible blocking dialog is confirmed.

#### Scenario: Background timeout
- **WHEN** window ID 71 tab 2 times out, no visible dialog is confirmed, and a fresh query reports current tab 1 of 3 with a matching target URL
- **THEN** stderr advises rechecking the target, focusing with the same target flags and inspecting dialog list; the original timeout is still returned

#### Scenario: Unknown or stale observation
- **WHEN** the query fails, lacks complete fields, reports invalid tab indices, or the target URL no longer matches its original matcher
- **THEN** no background assertion is emitted and the original result is preserved

#### Scenario: Empty background text
- **WHEN** get text returns an empty string and fresh background state is confirmed without a visible blocking dialog
- **THEN** the background hint is emitted and the result remains a successful empty string

### Requirement: Read-only bounded observation
The observation SHALL use stable window and fixed tab coordinates, avoid JavaScript/AX/HID/mutation, and have a bounded subprocess timeout. Normal successful non-empty results and targets without a stable fixed-tab anchor SHALL NOT start this observation. A confirmed visible blocking dialog SHALL take precedence. No focus, dismissal or action retry SHALL occur automatically.

#### Scenario: Current target and normal success
- **WHEN** a command succeeds with non-empty data, or refers only to a window's current tab without a fixed tab anchor
- **THEN** no background diagnostic query is added

### Requirement: Honest live verification
The live test SHALL create and clean up only its own identified fixture and verify the real background pending-dialog behavior. A locked session SHALL report an unperformed check rather than a pass.

#### Scenario: Locked desktop
- **WHEN** the GUI test detects a locked session
- **THEN** it exits with the documented unavailable code without interacting with Safari
