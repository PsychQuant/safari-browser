## ADDED Requirements

### Requirement: Window dialog annotations
Documents and tabs listings SHALL annotate each row with the visible native-dialog state of its retained stable window ID. One bounded shared observation SHALL serve the whole listing. JSON SHALL include blocking_dialog state, window_id, messages and reason. Text SHALL append only present markers without changing existing row identity, ordering, profile fields or the first three tabs TSV fields. Clear and unknown rows SHALL retain their original text. Unknown observations SHALL be reported on stderr unless explicitly disabled; JSON SHALL always retain their state and reason.

#### Scenario: Stable association
- **WHEN** rows from window ID 71 and 72 are listed and a complete observation contains a dialog only in 72
- **THEN** every row belonging to 72 is marked present and observed rows from 71 are clear, irrespective of later window ordering

### Requirement: Unknown is not clear
A row SHALL be clear only if a complete observation includes its valid stable ID and finds no dialog there. Disabled, denied, locked, incomplete, missing-identity and unobserved-window cases SHALL be unknown. Unknown SHALL remain explicit in JSON and in stderr diagnostics; an explicit opt-out SHALL suppress the text diagnostic. An observation SHALL NOT authorize dismissal or prove that background pending dialogs are absent.

#### Scenario: Missing and failed observation
- **WHEN** a row has no stable ID or the AX snapshot is incomplete
- **THEN** it reports unknown rather than no dialog, and ordinary listing data remains available

#### Scenario: Opt out
- **WHEN** automatic probing is explicitly disabled
- **THEN** no AX observation runs and JSON rows carry unknown with a disabled reason and text rows retain their original format without a new dialog warning

### Requirement: Existing scan and listing contracts
The new observation SHALL preserve existing dialog scan verdicts and the shared bounded-worker behavior. Ordinary discovery SHALL NOT activate tabs, dismiss dialogs or synthesize input. CLI and daemon opt-out settings SHALL remain effective. GUI acceptance SHALL be distinguished from injected tests.

#### Scenario: No dialog
- **WHEN** a complete snapshot includes the listed window with no visible native candidate
- **THEN** its state is clear while the existing scan result remains none

#### Scenario: Daemon documents parity
- **WHEN** an in-process exec documents step runs with a per-request probe setting
- **THEN** it uses the same row encoder and observation as the CLI, and the request setting controls whether AX runs
