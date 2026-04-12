## ADDED Requirements

### Requirement: Target document selection via CLI flags

The system SHALL provide four mutually exclusive global CLI flags that select the target Safari document for any subsequent subcommand: `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>`. If no target flag is provided, the system SHALL default to the first document in Safari's document collection (`document 1`). If more than one target flag is supplied in a single invocation, the system SHALL reject the invocation with a validation error before executing the subcommand.

#### Scenario: Default targeting with no flags

- **WHEN** user runs `safari-browser get url` with no target flag
- **THEN** the system resolves the target to `document 1` of Safari
- **AND** the command returns the URL of that document

#### Scenario: URL substring targeting

- **WHEN** user runs `safari-browser --url "plaud" get url`
- **AND** Safari has multiple documents, one of which has `https://web.plaud.ai/` as its URL
- **THEN** the system resolves the target to the first document whose URL contains the substring `plaud`
- **AND** the command returns `https://web.plaud.ai/`

#### Scenario: Window index targeting

- **WHEN** user runs `safari-browser --window 2 get url`
- **AND** Safari has at least two windows
- **THEN** the system resolves the target to the document of the second window (1-indexed)
- **AND** the command returns that window's document URL

#### Scenario: Document index targeting

- **WHEN** user runs `safari-browser --document 3 get url`
- **AND** Safari has at least three documents in its document collection
- **THEN** the system resolves the target to `document 3`
- **AND** the command returns that document's URL

#### Scenario: Tab alias for document

- **WHEN** user runs `safari-browser --tab 2 get url`
- **THEN** the system treats `--tab 2` identically to `--document 2`
- **AND** the command returns the URL of `document 2`

#### Scenario: Mutually exclusive flags rejected

- **WHEN** user runs `safari-browser --url plaud --window 2 get url`
- **THEN** the system SHALL print a usage error identifying the mutually exclusive flags
- **AND** the system SHALL exit with a non-zero status before invoking any Safari operation

---
### Requirement: Document reference resolution

The system SHALL expose a `TargetDocument` value type with exactly four cases (`frontWindow`, `windowIndex(Int)`, `urlContains(String)`, `documentIndex(Int)`) and a resolution helper that maps each case to a valid AppleScript document reference expression. The reference expression MUST be safe to interpolate inside `tell application "Safari" to ...` without additional escaping beyond the existing `escapedForAppleScript` string helper.

#### Scenario: Front window resolves to document 1

- **WHEN** `TargetDocument.frontWindow` is resolved
- **THEN** the returned AppleScript reference SHALL be `document 1`

#### Scenario: Window index resolves to document of window n

- **WHEN** `TargetDocument.windowIndex(2)` is resolved
- **THEN** the returned AppleScript reference SHALL be `document of window 2`

#### Scenario: URL substring resolves with AppleScript-escaped pattern

- **WHEN** `TargetDocument.urlContains("plaud")` is resolved
- **THEN** the returned AppleScript reference SHALL be `first document whose URL contains "plaud"`
- **AND** any double quotes or backslashes in the pattern SHALL be escaped per `escapedForAppleScript`

#### Scenario: Document index resolves to document n

- **WHEN** `TargetDocument.documentIndex(3)` is resolved
- **THEN** the returned AppleScript reference SHALL be `document 3`

---
### Requirement: Read-only query bypasses window-level modal blocks

The system SHALL route read-only document queries (getting URL, title, text, source, executing JavaScript) through document-scoped AppleScript references (`document N`), not window-scoped references (`current tab of front window`). This bypass SHALL remain effective even when Safari's front window has an active modal file dialog sheet that blocks window-scoped AppleScript dispatch.

#### Scenario: Get URL succeeds while front window shows modal sheet

- **WHEN** Safari's front window currently displays a modal file dialog sheet
- **AND** user runs `safari-browser get url`
- **THEN** the command SHALL return the URL within the default process timeout (30 s)
- **AND** the command SHALL NOT hang waiting for the sheet to be dismissed

#### Scenario: Read-only query respects target override during modal block

- **WHEN** Safari has two documents and the front window has a modal sheet open
- **AND** user runs `safari-browser --document 2 get url`
- **THEN** the command returns document 2's URL without waiting for the modal

---
### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the URLs of all currently available documents so the user can correct their target without running an additional command.

#### Scenario: URL substring with no matching document

- **WHEN** Safari has documents `[https://web.plaud.ai/, https://platform.claude.com/]`
- **AND** user runs `safari-browser --url xyz get url`
- **THEN** the system SHALL throw `documentNotFound` with `pattern: "xyz"` and `availableDocuments` listing both URLs
- **AND** the error description SHALL contain both `https://web.plaud.ai/` and `https://platform.claude.com/`

#### Scenario: Window index out of range

- **WHEN** Safari has one window
- **AND** user runs `safari-browser --window 5 get url`
- **THEN** the system SHALL throw `documentNotFound` identifying the requested window index
- **AND** the error description SHALL list available windows

---
### Requirement: Backward compatibility with existing scripts

The system SHALL NOT change behavior for invocations that omit all target flags, beyond switching the default read-only query from `current tab of front window` to `document 1`. In single-window Safari usage, `document 1` MUST be equivalent to `current tab of front window`, so existing scripts that assume the legacy target SHALL continue to work without modification.

#### Scenario: Single-window default targeting matches legacy

- **WHEN** Safari has exactly one window with one tab
- **AND** user runs `safari-browser get url` without any target flag
- **THEN** the returned URL MUST equal the URL of `current tab of front window`

#### Scenario: Keystroke operations preserve front-window semantics

- **WHEN** user runs `safari-browser upload --native <input> <file>` without any target flag
- **THEN** keystroke-driven operations SHALL continue to target `front window`
- **AND** SHALL NOT be redirected to a non-focused document
