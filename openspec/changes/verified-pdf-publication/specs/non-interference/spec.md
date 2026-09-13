## MODIFIED Requirements

### Requirement: Native file confirmation authorization

Initial Open/Save confirmation SHALL be a named exception within an authorized native file operation for the caller-specified path. The command SHALL emit its existing keyboard-control warning before GUI interaction. The initial confirmation SHALL locate one enabled button named Open, Upload, Save, 打開, 開啟, 上傳, or 儲存 among the file sheet’s direct buttons and split-group buttons, and record its title. It SHALL check that Safari is frontmost, the file sheet remains present, and no nested sheet is present. Missing, ambiguous, disabled, or unsupported-language buttons SHALL fail without confirmation. Lookup and dispatched-click errors SHALL propagate without a Return fallback or retry.

The file-dialog runner SHALL relay captured stderr after the subprocess finishes, including success, failure, and timeout. The trace SHALL escape terminal controls, be bounded to 4096 rendered scalars, and mark truncation. This is a record of attempted actions, not proof of their success or an announcement delivered before the button press; the separate keyboard-control warning remains the pre-interaction announcement.

PDF final-destination replacement SHALL require explicit `--overwrite` in addition to `--allow-hid`. PDF SHALL use a unique private staging path and publish only a verified independent snapshot. Existing unauthorized destinations SHALL fail before GUI interaction, and late unauthorized destinations SHALL fail through atomic no-replace. Authorized publication SHALL replace the specified directory entry rather than following a leaf symlink. Any additional native staging confirmation SHALL be refused without a Replace or Return fallback. The native initial Save exception covers the staging step of the requested export, not arbitrary dialogs.

This exception SHALL apply only to the file dialog opened by the requested operation. It SHALL NOT authorize confirmation of arbitrary JavaScript dialogs or other dialogs found on screen. The existing upload system-grant exception SHALL remain unchanged.

#### Scenario: Initial native file selection

- **WHEN** the caller authorizes native upload or PDF export for a specified path
- **THEN** its initial confirmation is permitted and records the named button title
- **AND** the captured trace is relayed safely after the subprocess finishes

#### Scenario: Lookup failure before initial confirmation

- **WHEN** initial button lookup fails before click dispatch
- **AND** fresh checks confirm Safari is frontmost and the file sheet exists without a nested sheet
- **THEN** the command fails without dispatching a confirmation or Return

#### Scenario: Initial press has an uncertain result

- **WHEN** a dispatched initial button click reports an error
- **THEN** the error is propagated without sending Return

#### Scenario: Separate overwrite permission

- **WHEN** PDF has only `--allow-hid` and the effective destination exists initially or appears later
- **THEN** the destination is preserved and export fails before GUI or at atomic publication, respectively

#### Scenario: Additional staging confirmation

- **WHEN** an unexpected native confirmation appears while exporting to the unique staging path
- **THEN** the command refuses it without Replace, default-button or Return dispatch
