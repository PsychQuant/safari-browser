## MODIFIED Requirements

### Requirement: Get element text by selector

The system SHALL print the textContent of the first element matching the CSS selector when a selector argument is provided to `get text`.

#### Scenario: Get text of specific element

- **WHEN** user runs `safari-browser get text "h1.title"`
- **THEN** stdout contains the textContent of the first `h1.title` element

#### Scenario: Element not found

- **WHEN** user runs `safari-browser get text ".nonexistent"`
- **THEN** the CLI exits with non-zero status and stderr contains "Element not found"

#### Scenario: Get full page text (no selector)

- **WHEN** user runs `safari-browser get text` without a selector
- **THEN** stdout contains the full page text via Safari's native `text` property (existing behavior preserved)

### Requirement: Get element HTML by selector

The system SHALL print the innerHTML of the first element matching the CSS selector.

#### Scenario: Get inner HTML

- **WHEN** user runs `safari-browser get html "div.content"`
- **THEN** stdout contains the innerHTML of the first `div.content` element

### Requirement: Get input value by selector

The system SHALL print the value property of the first input/textarea matching the CSS selector.

#### Scenario: Get input value

- **WHEN** user runs `safari-browser get value "input#email"`
- **THEN** stdout contains the current value of the input

### Requirement: Get element attribute by selector

The system SHALL print the value of the named attribute on the first element matching the CSS selector.

#### Scenario: Get href attribute

- **WHEN** user runs `safari-browser get attr "a.link" "href"`
- **THEN** stdout contains the href attribute value

### Requirement: Get element count by selector

The system SHALL print the number of elements matching the CSS selector.

#### Scenario: Count matching elements

- **WHEN** user runs `safari-browser get count "li.item"` and there are 5 matching elements
- **THEN** stdout contains `5`

#### Scenario: No matching elements

- **WHEN** user runs `safari-browser get count ".nonexistent"`
- **THEN** stdout contains `0`
