# snapshot-page Specification

## Purpose

TBD - created by archiving change 'snapshot-page'. Update Purpose after archive.

## Requirements

### Requirement: Full page state scan

When the `--page` flag is provided, the system SHALL scan the entire visible DOM using a TreeWalker and output a structured text representation of the page state. The output SHALL include:

1. **Page metadata block** — URL (`window.location.href`), title (`document.title`), loading state (`document.readyState`)
2. **Accessibility tree** — all visible elements with their implicit or explicit ARIA roles, organized by DOM hierarchy with indentation
3. **Interactive elements with @ref** — interactive elements SHALL be assigned `@eN` refs via `window.__sbRefs` (identical mechanism to the existing `snapshot` command)
4. **Non-interactive content** — headings (`h1`-`h6` with level), text nodes (trimmed, non-empty), landmarks (`nav`, `main`, `aside`, `header`, `footer`), lists (`ul`/`ol` → `li`)
5. **Live regions** — elements with `aria-live` attribute SHALL be included with their current text content
6. **Dialog state** — open `<dialog>` elements and elements with `[role=dialog][aria-modal=true]` SHALL be reported
7. **Form validation** — `input`/`select`/`textarea` elements that fail `checkValidity()` SHALL be listed with their `validationMessage`

Elements with `display: none`, `visibility: hidden`, or `aria-hidden="true"` SHALL be excluded from the output.

#### Scenario: Page scan of a dashboard

- **WHEN** user runs `safari-browser snapshot --page` on a page with heading, nav links, a status alert, and interactive buttons
- **THEN** the output includes a metadata block (URL, title, readyState), headings with level, nav landmark with links as `@ref` elements, the alert text, and buttons with `@ref` IDs

#### Scenario: Page scan with open dialog

- **WHEN** user runs `safari-browser snapshot --page` on a page with an open modal dialog containing a form
- **THEN** the output includes `[dialog aria-modal=true]` with the dialog's content indented beneath it, including any form fields with `@ref` IDs

#### Scenario: Page scan with form validation errors

- **WHEN** user runs `safari-browser snapshot --page` on a page where a required email field is empty and invalid
- **THEN** the output includes the email input with its `@ref` and `[invalid: "Please fill out this field"]` annotation

#### Scenario: Page scan excludes hidden elements

- **WHEN** user runs `safari-browser snapshot --page` on a page with elements that have `display: none` or `aria-hidden="true"`
- **THEN** those elements and their descendants do not appear in the output


<!-- @trace
source: snapshot-page
updated: 2026-04-08
code:
-->

---
### Requirement: Page scan output format

The output of `snapshot --page` SHALL use indented plain text with the following format:

```
URL: <url>
Title: <title>
Loading: <readyState>

[heading level=N] <text>
[text] <content>
[landmark type] <name>
  @eN <tag> <descriptors> <label>
  [text] <content>
[alert aria-live=polite] <text>
[dialog aria-modal=true]
  ...content...
[invalid] @eN input — <validationMessage>
```

Lines SHALL be indented by 2 spaces per DOM depth level relative to the nearest landmark or root.

When `--json` is also provided, the output SHALL be a JSON object with keys: `url`, `title`, `readyState`, `tree` (array of node objects), `refs` (array of interactive element objects), `validation` (array of invalid fields).

#### Scenario: Plain text output

- **WHEN** user runs `safari-browser snapshot --page`
- **THEN** the output is indented plain text, one element per line, with metadata at the top

#### Scenario: JSON output

- **WHEN** user runs `safari-browser snapshot --page --json`
- **THEN** the output is a JSON object containing `url`, `title`, `readyState`, `tree`, `refs`, and `validation` keys


<!-- @trace
source: snapshot-page
updated: 2026-04-08
code:
-->

---
### Requirement: Page scan truncation

When the output exceeds 2000 lines, the system SHALL truncate and append a footer line:

```
... truncated (N total lines). Use -s "<selector>" to narrow scope.
```

The truncation SHALL preserve complete elements — lines SHALL NOT be cut mid-element.

#### Scenario: Large page truncation

- **WHEN** user runs `safari-browser snapshot --page` on a page that produces 5000 lines of output
- **THEN** the output contains exactly 2000 lines of content plus a truncation footer with the total line count and a hint to use `-s`


<!-- @trace
source: snapshot-page
updated: 2026-04-08
code:
-->

---
### Requirement: Page scan respects scope flag

The existing `-s <selector>` flag SHALL work with `--page` to limit the scan to descendants of the specified element. Page metadata (URL, title, readyState) SHALL still be included regardless of scope.

#### Scenario: Scoped page scan

- **WHEN** user runs `safari-browser snapshot --page -s "main"`
- **THEN** the metadata block shows the full page URL/title, but the accessibility tree only includes elements inside the `<main>` element

<!-- @trace
source: snapshot-page
updated: 2026-04-08
code:
-->
