## ADDED Requirements

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
