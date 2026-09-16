## MODIFIED Requirements

### Requirement: Explicit opt-in for interfering operations

Commands that require Human Interface Device (HID) control, system dialogs, or other interfering behavior MUST require an explicit opt-in flag. The CLI MUST NOT perform interfering operations unless the user has passed the corresponding flag.

The following opt-in flags are defined:

| Flag | Permits |
|---|---|
| `--allow-hid` | Keyboard/mouse control via System Events |
| `--native` | Native file dialog interaction via System Events |
| `--mark-tab` / `--mark-tab-persist` | Wraps target tab title with the zero-width ownership marker — passively interfering when opted in. See `tab-ownership-marker` capability. |

Future commands that introduce new categories of interference MUST define a new opt-in flag or reuse an existing one if the interference category matches.

#### Exception: `upload`'s native path under an Accessibility grant

This is a **single named exception**, not a general rule. It applies to `upload` and to no other command. Any other command that wants to substitute a system grant for a flag MUST amend this spec first — "`upload` already does it" is not an argument that carries.

**What is exempted.** When the macOS Accessibility grant is present, `upload` SHALL take its native path with no flag unless --js is supplied. That path is a composite, and the exemption covers the whole of it: opening the file chooser, activating its Safari target, and temporarily using the file URL clipboard. These remain interference under the `MUST NOT` above even though native upload no longer dispatches keyboard events.

**Conditions.** The exemption holds only while all of these hold:

1. `upload` emits the `Interference warning on stderr` required below, on the native path, before the interference begins.
2. A caller without the grant still gets a non-interfering path for the ordinary case — JS DataTransfer, which handles files up to its 10 MB cap.
3. Explicit `--native` / `--allow-hid` continue to select the native path, which still requires the system grant for Accessibility actions. The exemption adds a way to authorize; it does not remove the existing one.

**Where condition 2 stops.** Above 10 MB the JS path cannot do the job, so a caller without the grant does not get a slower upload — they get a failed one. For files over the cap the command is genuinely unavailable without either the grant or an explicit flag. That is a real hole in the "degrades rather than breaks" story, and it is written down rather than smoothed over.

**What this trades away, stated plainly.** A TCC grant is given once, to the whole CLI, in System Settings. A flag is given per invocation. Treating the first as consent for the second is not an identity — a user who granted Accessibility so that `screenshot` could resolve windows did not thereby ask `upload` to change focus or temporarily use their clipboard. The exemption buys a materially better default and pays for it with that gap. Condition 1 is what keeps the gap visible: the user is told, every time, at the moment it happens.

`pdf` does **not** use this exemption — it hard-fails without `--allow-hid`, even with Accessibility granted.

> **Provenance.** This documents behavior that shipped in `7e6062a` (change `clipboard-path-input`, #14) without a corresponding spec delta. That change listed `non-interference` in its Impact but characterized the effect as "鍵盤控制時間大幅縮短" — shorter keyboard control — rather than as a change to *what triggers* the interference. The conflict with the `MUST NOT` above went unrecorded until #104. It is written down here as a deliberate, narrow exemption with its cost, rather than left as drift or generalized into a rule nobody decided on.

#### Exception: initial confirmation of the caller's native file operation

A native `upload` or an authorized `pdf` operation SHALL be permitted to confirm the initial Open/Save sheet for the caller-specified path. Choosing that path and requesting the operation authorizes its initial confirmation; leaving the command's own chooser open would prevent that operation from finishing and can block later Safari commands (#67). This exception is limited by `Native file confirmation authorization` below. It does not change the preceding upload system-grant exception, authorize a PDF overwrite, or permit confirmation of unrelated dialogs.

#### Scenario: Upload without flags, no Accessibility, file within the JS cap

- **WHEN** a user runs `safari-browser upload "input[type=file]" /path/to/file.pdf` without flags, the Accessibility grant is absent, **and** the file is at or under the 10 MB JS cap
- **THEN** the file is injected via JavaScript DataTransfer API without opening a file dialog or controlling the keyboard, and the command notes on stderr that granting Accessibility would enable the faster native path

#### Scenario: Upload without flags, no Accessibility, file over the JS cap

- **WHEN** the same command runs on a file larger than 10 MB
- **THEN** the command fails rather than falling back to interference — the size cap is enforced, no dialog is opened and no keystroke is sent, and the error points at `--native` and states that it needs the Accessibility grant

#### Scenario: Upload without flags but with Accessibility uses the native dialog

- **WHEN** a user runs `safari-browser upload "input[type=file]" /path/to/file.pdf` without flags **and** the Accessibility grant is present
- **THEN** the command takes the native file-dialog path under the `upload` exemption above, and emits the native-dialog, focus and clipboard warning to stderr before native interference

#### Scenario: Upload with --native uses file dialog

- **WHEN** a user runs `safari-browser upload "input[type=file]" /path/to/file.pdf --native`
- **THEN** the command opens the native macOS file dialog and uses named Accessibility actions and a file URL pasteboard to select the file

#### Scenario: PDF export requires --allow-hid

- **WHEN** a user runs `safari-browser pdf /tmp/page.pdf` without `--allow-hid`
- **THEN** the command exits with an error indicating that `--allow-hid` is required

---
Native upload SHALL NOT use the upload exception to dispatch HID events; it SHALL retain the exception only for native-dialog, focus and temporary clipboard interference. PDF HID authorization SHALL remain unchanged.

### Requirement: Native file confirmation authorization

Initial Open/Save confirmation SHALL be a named exception within an authorized native file operation for the caller-specified path. The command SHALL emit its applicable interference warning before GUI interaction; native upload SHALL name its focus, file-dialog and clipboard interference instead of claiming keyboard control. The initial confirmation SHALL locate one enabled button named Open, Upload, Save, 打開, 開啟, 上傳, or 儲存 among the file sheet’s direct buttons and split-group buttons, and record its title. It SHALL check that Safari is frontmost, the file sheet remains present, and no nested sheet is present. Missing, ambiguous, disabled, or unsupported-language buttons SHALL fail without confirmation. Lookup and dispatched-click errors SHALL propagate without a Return fallback or retry.

The file-dialog runner SHALL relay captured stderr after the subprocess finishes, including success, failure, and timeout. The trace SHALL escape terminal controls, be bounded to 4096 rendered scalars, and mark truncation. This is a record of attempted actions, not proof of their success or an announcement delivered before the button press; the separate applicable interference warning remains the pre-interaction announcement.

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

Native upload SHALL NOT use the upload exception to dispatch HID events; it SHALL retain the exception only for native-dialog, focus and temporary clipboard interference. PDF HID authorization SHALL remain unchanged.

### Requirement: Interference warning on stderr

When a command activates an interfering operation — whether authorized by an opt-in flag or by the system-grant exception above — it MUST emit a warning to stderr before the interfering operation begins. The warning MUST indicate:

1. What type of interference will occur (e.g., "keyboard control", "file dialog")
2. That the user must avoid interacting with the affected native dialog or clipboard during the operation; HID operations SHALL additionally state that input devices are temporarily unavailable

The warning MUST NOT be emitted to stdout (to avoid polluting command output).

#### Scenario: HID warning before keyboard control

- **WHEN** a user runs `safari-browser upload "input" /path/to/file --allow-hid` and JS injection fails
- **THEN** before native interference, the command emits a warning to stderr: a message indicating native-dialog, focus and clipboard interference is active

#### Scenario: HID warning on the grant-authorized path too

- **WHEN** a user runs `safari-browser upload "input" /path/to/file` with no flag, and the Accessibility grant makes the command take the native path
- **THEN** the warning is emitted just as it would be under `--allow-hid` — the exception relaxes which authorization is required, never whether the user is told

#### Scenario: No warning for non-interfering commands

- **WHEN** a user runs `safari-browser click "button"` (non-interfering, JS-based)
- **THEN** no interference warning is emitted to stderr

---
Native upload SHALL NOT use the upload exception to dispatch HID events; it SHALL retain the exception only for native-dialog, focus and temporary clipboard interference. PDF HID authorization SHALL remain unchanged.
