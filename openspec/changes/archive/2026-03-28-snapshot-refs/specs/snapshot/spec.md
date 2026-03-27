## ADDED Requirements

### Requirement: Scan interactive elements and assign refs

The system SHALL scan the current page's DOM for interactive elements and assign sequential ref IDs (`@e1`, `@e2`, ...). The element references SHALL be stored in `window.__sbRefs` as an array. The output SHALL list each element with its ref ID, tag, type, and descriptive text.

#### Scenario: Snapshot a login form

- **WHEN** user runs `safari-browser snapshot` on a page with an email input, password input, and submit button
- **THEN** stdout contains lines like:
  ```
  @e1  input[type="email"]  placeholder="Email"
  @e2  input[type="password"]  placeholder="Password"
  @e3  button  "Sign In"
  ```
  and `window.__sbRefs` contains the 3 DOM elements

#### Scenario: Snapshot empty page

- **WHEN** user runs `safari-browser snapshot` on a page with no interactive elements
- **THEN** stdout is empty and `window.__sbRefs` is an empty array

### Requirement: Interactive-only filter

The system SHALL scan only interactive elements by default: `input`, `button`, `a`, `select`, `textarea`, `[role="button"]`, `[role="link"]`, `[role="menuitem"]`, `[role="tab"]`, `[contenteditable]`, and elements with `onclick` attribute.

#### Scenario: Non-interactive elements excluded

- **WHEN** user runs `safari-browser snapshot` on a page with divs, spans, and paragraphs alongside a button
- **THEN** only the button appears in the output

### Requirement: Scope snapshot to selector

The system SHALL support `--selector` (`-s`) option to limit scanning to descendants of the first element matching the given CSS selector.

#### Scenario: Scoped snapshot

- **WHEN** user runs `safari-browser snapshot -s "form.login"`
- **THEN** only interactive elements within `form.login` are listed

### Requirement: Re-snapshot replaces refs

The system SHALL clear and replace `window.__sbRefs` on each snapshot invocation. Previous refs become invalid.

#### Scenario: Re-snapshot after navigation

- **WHEN** user runs `safari-browser snapshot`, then navigates to another page, then runs `safari-browser snapshot` again
- **THEN** the new snapshot replaces all previous refs
