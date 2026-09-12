## ADDED Requirements

### Requirement: Shared bounded worker
Global dialog reads SHALL wait at most 800 ms for inspection and SHALL share one in-flight AX worker allowance with the existing 95 ms entry probes. A busy allowance SHALL return unknown without queueing. Late results SHALL remain isolated from subsequent calls.

#### Scenario: A provider remains blocked
- **WHEN** an AX read exceeds the global deadline and a second global or entry probe arrives
- **THEN** the first caller returns incomplete within its waiting budget and the second returns unknown without creating another worker.

### Requirement: Complete global scanner
A global answer of none or one SHALL require complete window enumeration, valid unique window IDs, complete native-tree traversal and complete candidate details. Read failures, deadlines, and depth/node/window truncation SHALL remain incomplete. WebArea subtrees SHALL be excluded from native dialog discovery and details. Multiple known candidates SHALL remain ambiguous. Unsupported or absent optional text/title attributes SHALL remain absent rather than count as failed reads; unnamed buttons SHALL be omitted from both the title and element lists. Unknown text-area editability SHALL remain incomplete.

#### Scenario: Fifteen readable windows
- **WHEN** fifteen readable windows contain no native dialog
- **THEN** dialog list returns the existing no-dialog message within one second.

#### Scenario: A late window cannot be read
- **WHEN** fourteen windows are clear and the fifteenth fails to respond
- **THEN** dialog list exits nonzero with an incomplete-inspection diagnostic rather than reporting no dialog.

#### Scenario: A complete native dialog
- **WHEN** one complete native dialog is present and all other windows are fully inspected
- **THEN** dialog list returns its source heading, readable body and button titles within one second.

### Requirement: Strict command integration
Dismissal SHALL synchronously re-inspect using the complete global scanner before invoking its existing decision callback. Only a complete single candidate SHALL authorize a press. The pressed element SHALL come from the same ordered button snapshot used to decide its index. Session state and remaining deadline SHALL be checked before AXPress. An abandoned background inspection SHALL never perform a press.

#### Scenario: The second scan is incomplete
- **WHEN** a prior list succeeded but the dismissal scan cannot inspect another window
- **THEN** no decision or press callback is invoked and dismissal reports incomplete inspection.

#### Scenario: The chosen snapshot remains valid
- **WHEN** the complete re-read matches the expected message and ordered titles
- **THEN** the existing named-button rule selects the corresponding element from that same re-read, with existing uncertain-delivery errors preserved.
