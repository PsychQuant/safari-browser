# pdf-export Specification

## Purpose

TBD - created by archiving change 'parity-with-agent-browser'. Update Purpose after archive.

## Requirements

### Requirement: Export page as PDF

The PDF export file dialog SHALL use the same shared dialog navigation function as upload:
1. Clipboard paste (`Cmd+V`) for path input instead of `keystroke`
2. `repeat until exists` polling instead of fixed `delay` for all dialog state transitions
3. `AXDefault` button for confirm with `keystroke return` fallback
4. Save and restore clipboard content

#### Scenario: PDF export uses clipboard for path

- **WHEN** user runs `safari-browser pdf --allow-hid /tmp/page.pdf`
- **THEN** the path is entered via clipboard paste, not keystroke, completing in under 1 second of keyboard control

#### Scenario: PDF export uses precise waits

- **WHEN** user runs `safari-browser pdf --allow-hid /tmp/page.pdf`
- **THEN** dialog transitions use `repeat until exists` polling, not fixed `delay 1`

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
