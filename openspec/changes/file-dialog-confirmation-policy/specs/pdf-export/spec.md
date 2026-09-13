## MODIFIED Requirements

### Requirement: Export page as PDF

The PDF export file dialog SHALL use the same shared dialog navigation function as upload:
1. Clipboard paste (`Cmd+V`) for path input instead of `keystroke`
2. `repeat until exists` polling instead of fixed `delay` for all dialog state transitions
3. Initial confirmation of a unique enabled, named Open/Upload/Save button (including supported Traditional Chinese labels), after frontmost and non-nested-sheet checks; no Return fallback or retry
4. Save and restore clipboard content

#### Scenario: PDF export uses clipboard for path

- **WHEN** user runs `safari-browser pdf --allow-hid /tmp/page.pdf`
- **THEN** the path is entered via clipboard paste, not keystroke, completing in under 1 second of keyboard control

#### Scenario: PDF export uses precise waits

- **WHEN** user runs `safari-browser pdf --allow-hid /tmp/page.pdf`
- **THEN** dialog transitions use `repeat until exists` polling, not fixed `delay 1`

Replacement SHALL require `--overwrite` (default false) in addition to `--allow-hid`. An existing destination without authorization SHALL be rejected before target resolution or GUI operations; a replacement sheet appearing later SHALL also be refused without authorization. Authorized replacement SHALL use only a unique named `Replace` or `取代` button. Missing, ambiguous, and unsupported-language names SHALL be refused. Replacement SHALL NOT use Return fallback or retry a dispatched press after an error.

Initial confirmation and replacement attempts SHALL be recorded by the file-dialog runner's bounded, terminal-escaped stderr trace after subprocess completion, including failure or timeout. This trace SHALL NOT replace the keyboard-control warning emitted before GUI interaction.

#### Scenario: Existing destination without authorization

- **WHEN** the destination exists and `--overwrite` is absent
- **THEN** the PDF command refuses before target resolution or GUI interaction

#### Scenario: Destination appears after preflight

- **WHEN** the destination appears after the existence check and a replacement sheet opens
- **AND** `--overwrite` is absent
- **THEN** no replacement confirmation is dispatched

#### Scenario: Authorized replacement

- **WHEN** the caller supplies both `--allow-hid` and `--overwrite`
- **AND** the replacement sheet has a unique `Replace` or `取代` button
- **THEN** the command records and dispatches that button press
- **AND** a press error does not cause a Return retry
