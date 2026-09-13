# pdf-export Specification

## Purpose

Define native Safari PDF export, shared file-dialog navigation, explicit overwrite authorization and target selection.

## Requirements

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

---
### Requirement: PDF export command accepts full TargetOptions

The `pdf` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags in addition to the existing `--allow-hid` requirement. When targeting flags are supplied, the system SHALL resolve the target to a physical window index via the native path resolver, switch to the target tab if needed, raise that window to the front, and dispatch the PDF file-dialog keystroke sequence against the resolved window.

The `pdf` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time.

#### Scenario: pdf --url resolves to target window

- **WHEN** Safari has two windows, one showing `https://docs.example.com/`
- **AND** user runs `safari-browser pdf --url docs --allow-hid /tmp/docs.pdf`
- **THEN** the system SHALL resolve `--url docs` to the docs window index
- **AND** SHALL raise that window
- **AND** SHALL dispatch the PDF file-dialog keystroke sequence against that window

#### Scenario: pdf --document resolves via document collection

- **WHEN** Safari has three documents across two windows
- **AND** user runs `safari-browser pdf --document 3 --allow-hid /tmp/third.pdf`
- **THEN** the system SHALL identify which window owns the third document
- **AND** SHALL raise that window and dispatch the PDF dialog

#### Scenario: pdf --url with no match

- **WHEN** Safari has no window whose URL contains `xyz`
- **AND** user runs `safari-browser pdf --url xyz --allow-hid /tmp/out.pdf`
- **THEN** the system SHALL throw `documentNotFound` before dispatching any keystroke

<!-- @trace
source: clipboard-path-input
updated: 2026-04-07
code:
-->
