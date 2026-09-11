## ADDED Requirements

### Requirement: Stable target probing
Entry probes SHALL identify the target by a positive stable window ID and match Accessibility windows by that ID. AX list order and a focused non-browser window MUST NOT select a different target. Missing identity or failed ID reads SHALL be unprobed. An already-resolved positive ID absent from the AX list SHALL remain unprobed even when that list is empty.

#### Scenario: AX order differs
- **WHEN** AppleScript target ID is 42 and AX windows enumerate IDs 9 then 42
- **THEN** only window 42 is used to decide whether the target is blocked.

### Requirement: Expiring keyed verdicts
Gate state and refusal SHALL require an explicit target key and a fresh monotonic timestamp. A verdict SHALL expire after its TTL. Clear SHALL be distinct from Optional.none. Unscoped failure attribution MUST NOT use another window's dialog.

#### Scenario: Switching targets and expiration
- **WHEN** A has a present verdict, B is checked, and A subsequently expires
- **THEN** B is never refused using A's verdict and expired A no longer authorizes refusal.

### Requirement: Bounded complete probing
The entry probe SHALL bound each caller wait below 100 ms and SHALL share a total 200 ms probe budget across one logical command and SHALL keep at most one AX worker in flight. A busy worker SHALL cause immediate unprobed without queuing. WebArea descendants SHALL be excluded from native UI inspection; a page ARIA dialog MUST NOT be treated as a native blocker. Deadline, failed native-UI reads, and unexamined truncated native-UI branches SHALL produce unprobed, never clear. Late results MUST NOT modify a timed-out request's gate cache.

#### Scenario: Provider blocks
- **WHEN** window ID, role, children, text, or button reading stops responding
- **THEN** the caller returns unprobed within the waiting budget and a second request does not start another worker.

#### Scenario: Command exhausts its budget
- **WHEN** probes in one CLI command consume its 200 ms total budget
- **THEN** further uncached checks return unprobed without starting another probe, while a new daemon exec step receives its own 200 ms budget.

#### Scenario: Deep native dialog
- **WHEN** an AXDialog exists at depth 3 and all preceding reads succeed
- **THEN** the probe returns present.

### Requirement: Native command warnings
Targeted native operations SHALL invoke the gate after target resolution and before acting. This includes close, pdf, tab focus, upload, save-image, ordinary screenshot, and tabs with an explicit window. Warnings SHALL remain on stderr and MUST NOT by themselves fail a read-only operation.

#### Scenario: Window tab listing
- **WHEN** tabs --window resolves a window that has a blocking dialog
- **THEN** it emits the warning on stderr and retains its existing stdout format.

### Requirement: Honest probe tests
The test harness SHALL reject unavailable timing dependencies and malformed timing values before arithmetic. It SHALL distinguish environment skips from CLI errors, assert the measured probe budget, and verify ownership before dismissing a fixture dialog. Unit tests SHALL cover failed reads, incomplete traversal, Unicode line folding, and debug values.

#### Scenario: Invalid timing command
- **WHEN** timing fails or returns a non-integer
- **THEN** the harness fails rather than reporting a zero-millisecond pass.
