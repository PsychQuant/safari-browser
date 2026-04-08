## MODIFIED Requirements

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
