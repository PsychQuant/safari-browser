## ADDED Requirements

### Requirement: Compact snapshot mode

The system SHALL support `--compact` (`-c`) flag that excludes hidden elements (display:none, visibility:hidden, zero dimensions) from the snapshot output.

#### Scenario: Compact snapshot

- **WHEN** user runs `safari-browser snapshot -c` on a page with hidden inputs and visible buttons
- **THEN** only visible interactive elements appear in the output

### Requirement: Depth-limited snapshot

The system SHALL support `--depth` (`-d`) option that limits scanning to elements within N levels of DOM depth from the scope root.

#### Scenario: Depth 3 snapshot

- **WHEN** user runs `safari-browser snapshot -d 3`
- **THEN** only interactive elements within 3 levels of nesting from body are listed

### Requirement: Improved element descriptions

The snapshot output SHALL include element id (if present), first 3 CSS classes (if present), and disabled state.

#### Scenario: Element with id and classes

- **WHEN** an input has `id="email"` and `class="form-input lg primary"`
- **THEN** the snapshot line shows `@eN  input[type="email"]  #email .form-input.lg.primary  placeholder="Email"`

#### Scenario: Disabled element

- **WHEN** a button has the `disabled` attribute
- **THEN** the snapshot line includes `[disabled]`
