## ADDED Requirements

### Requirement: Bounded current-window observation

The native dialog query SHALL identify Safari's main window through Accessibility and inspect only that window with the shared strict dialog scanner. It SHALL use one shared AX worker and one total observation budget of at most 800 milliseconds, including identity reads and verification. It SHALL NOT queue work behind a busy worker or expose AX nodes outside it. It SHALL NOT execute JavaScript or Apple Events, activate Safari, switch windows or tabs, or press dialog buttons.

The query SHALL verify the same positive window ID before and after inspection. Failed identity reads, changed identity, denied Accessibility, unavailable GUI, incomplete reads, truncation, worker contention, and expired deadlines SHALL return unknown. It SHALL NOT substitute the first window, a title match, or another window's dialog.

#### Scenario: Click remains blocked by a native confirm

- **WHEN** an owned click process is still waiting for its confirm handler
- **AND** the current Safari window has an observable native dialog
- **THEN** an independent query returns present without waiting for that JavaScript invocation to finish
- **AND** the query performs no dismissal or focus change

#### Scenario: Another window has a dialog

- **WHEN** the current identified window is fully inspected and a different window has a dialog
- **THEN** the other window's dialog is not reported as present for the current window

#### Scenario: Current window identity changes

- **WHEN** the main-window ID changes between the initial and final reads
- **THEN** the query returns unknown rather than reporting the earlier window's state as current

### Requirement: Conservative pending-dialog absence

The query SHALL report clear only for a complete observation whose stable current window is non-minimized and on screen before and after inspection. The query SHALL NOT require Safari to be the foreground application. A complete observation with a dialog SHALL report present. An empty observation without those clear conditions SHALL report unknown, because hidden pending dialogs are not excluded. Results SHALL describe an observation of the current window's selected tab and SHALL NOT promise that a future operation or every background tab is free of pending dialogs.

#### Scenario: Hidden window has an empty native tree

- **WHEN** the current window has no observed dialog but the window is hidden or minimized
- **THEN** the result is unknown, not clear

#### Scenario: Stable visible window is clear without foreground activation

- **WHEN** a stable on-screen non-minimized main window is completely inspected without a dialog
- **THEN** the result is clear even while another application is in the foreground

### Requirement: Three-state command contract

The CLI SHALL provide `is dialog [--json]` without a selector or target-selection flags. Text output SHALL be true for present, false for clear, and unknown for unknown. Present and clear SHALL exit with code 0; unknown SHALL exit with code 2 and a reason on stderr. JSON output SHALL contain state, window_id, messages, and reason using the existing window-dialog status shape, and SHALL remain valid JSON on unknown outcomes.

Explicit queries SHALL remain enabled independently of the automatic entry-probe opt-out. The CLI and metadata-derived MCP tool SHALL enforce the same contract. Existing is visible, exists, enabled, and checked commands SHALL retain their behavior. Exec support SHALL remain unchanged.

#### Scenario: Unknown is not a false answer

- **WHEN** inspection cannot establish the current state
- **THEN** text mode prints unknown and exits 2
- **AND** JSON mode emits state unknown, the available window ID, and a reason, and exits 2

### Requirement: Live in-flight acceptance

Acceptance SHALL use an owned localhost fixture whose click opens confirm. The query SHALL return present within three seconds while the click process is still waiting. The fixture SHALL verify both clear and present while Safari is not the foreground application, verify clear before or after that pending state, verify exactly one handler execution, and confirm cleanup of every owned window and dialog. Recovery SHALL use the existing exact window/message guarded named dismissal without replay. Unavailable GUI SHALL be reported as a skipped test with exit 77, not a pass.

#### Scenario: End-to-end pending query and recovery

- **WHEN** the owned click opens confirm and an independent is dialog query is run
- **THEN** it returns true within three seconds before click completion
- **AND** guarded fixture recovery allows the click to finish exactly once and leaves all owned windows and dialogs closed
