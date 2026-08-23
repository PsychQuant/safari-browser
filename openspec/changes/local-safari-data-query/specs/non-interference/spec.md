## ADDED Requirements

### Requirement: Local data query commands are non-interfering

The `history`, `bookmarks`, `cloud-tabs`, and `downloads` commands SHALL be classified as **Non-interfering** under the conformance classification for new commands.

These commands read copies of Safari's on-disk data files. They do not control input devices, do not display system dialogs, do not produce sound, do not steal window focus, and do not require Safari to be running. They are therefore non-interfering under the existing definition, and SHALL NOT require an opt-in flag.

Requiring Full Disk Access does not change this classification. Interference level describes what a command does to the user's concurrent activity; it does not describe what permission the command needs.

#### Scenario: Local data query runs during unrelated user activity

- **WHEN** a user runs `safari-browser history --search example` while typing in another application
- **THEN** the command reads the copied history database and prints results without moving the cursor, changing window focus, producing sound, or interrupting the user's typing

#### Scenario: Local data query does not launch Safari

- **WHEN** a user runs `safari-browser downloads` while Safari is not running
- **THEN** the command completes without launching Safari and without bringing any window to the foreground

---

### Requirement: Data sensitivity is recorded separately from interference level

The system SHALL record, for each command that reads local Safari data, that its output exposes a broader scope of user data than commands which operate on the live browser.

Commands that operate on the live browser expose only what the user currently has open. The `history` and `downloads` commands expose a long-term record of user behavior across time. This distinction is orthogonal to interference level: a command can be fully non-interfering and still expose sensitive data.

New commands that read persisted user data SHALL state their data sensitivity alongside their interference classification, so that default output limits and documentation can be set deliberately rather than by analogy to live-browser commands.

#### Scenario: New persisted-data command declares sensitivity

- **WHEN** a developer proposes a new command that reads a persisted Safari data file
- **THEN** the proposal states both the interference level and whether the command exposes a long-term behavioral record, and sets a default output limit accordingly

#### Scenario: Behavioral-record commands carry a default limit

- **WHEN** a command exposes a long-term behavioral record
- **THEN** it applies a default result limit so that an unqualified invocation does not dump the entire record

---

### Requirement: The non-interfering definition covers read-only local file access

The conformance classification for new commands SHALL treat reading a file from disk,
without writing to it and without any HID, dialog, sound, or focus effect, as
**Non-interfering**.

The existing definition enumerates "JS, AppleScript property access, or silent utilities",
which names the mechanisms that existed before any command read the filesystem. A command
that reads a file is non-interfering for the same reason those are: it does nothing the
user can perceive while they work. Leaving the definition unamended would classify these
four commands by assertion while giving the next filesystem-reading command no rule to
apply.

Requiring a permission does not affect the classification. Interference level describes
what a command does to the user's concurrent activity, not what it needs permission to do.

#### Scenario: A new file-reading command is classified from the definition

- **WHEN** a developer proposes a command that reads a file under `~/Library/` and neither
  writes to it nor touches input devices, dialogs, sound, or window focus
- **THEN** the classification table yields **Non-interfering** directly, with no opt-in flag,
  and the developer states the command's data sensitivity separately
