## ADDED Requirements

### Requirement: Element interaction commands honor document targeting

All element-interaction commands (`click`, `fill`, `type`, `select`, `hover`, `scroll`, `dblclick`, `focus`, `press`, `drag`, `scroll-into-view`) SHALL execute their underlying JavaScript against the target document resolved from the global targeting flags. The default target SHALL be `document 1`. Global targeting flags (`--url`, `--window`, `--tab`, `--document`) SHALL redirect the JavaScript execution to the resolved document.

When an element cannot be located inside the resolved target document, the system SHALL throw `SafariBrowserError.elementNotFound(<selector>)`. It SHALL NOT fall back to searching other documents — targeting is strict.

#### Scenario: Click honors URL targeting

- **WHEN** Safari has two documents and user runs `safari-browser --url plaud click "button.submit"`
- **THEN** the click SHALL execute inside the document whose URL contains `plaud`
- **AND** SHALL NOT trigger any handler in the other document

#### Scenario: Fill honors window targeting

- **WHEN** user runs `safari-browser --window 2 fill "input#email" "user@example.com"`
- **THEN** the input is filled inside the document of window 2
- **AND** the same selector in window 1 SHALL remain unchanged

#### Scenario: Element not found is scoped to target

- **WHEN** Safari has two documents — one with `.submit`, one without
- **AND** user runs `safari-browser --document 2 click ".submit"`
- **AND** document 2 does not contain `.submit`
- **THEN** the CLI SHALL exit with non-zero status and stderr SHALL contain `Element not found: .submit`
- **AND** SHALL NOT click `.submit` in document 1

#### Scenario: Scroll honors targeting

- **WHEN** user runs `safari-browser --url plaud scroll down 200`
- **THEN** only the document whose URL contains `plaud` SHALL scroll
- **AND** other documents SHALL remain at their current scroll position

#### Scenario: Fast read-path bypasses modal block

- **WHEN** Safari's front window has an open modal file dialog sheet
- **AND** user runs `safari-browser click "button" --document 2`
- **THEN** the click SHALL execute inside document 2 within the process timeout
- **AND** SHALL NOT hang on the front window's modal
