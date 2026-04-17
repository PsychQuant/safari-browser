## ADDED Requirements

### Requirement: Spatial interference gradient for focus-existing

When a command (such as `open <url>` in its default focus-existing mode) needs to reveal an existing Safari tab that is not currently focused, the system SHALL classify the interference level based on the spatial relationship between the target tab and the currently frontmost Safari context. The classification SHALL map to concrete behavior according to the following gradient:

| Spatial layer | Condition | Behavior | Interference classification |
|---------------|-----------|----------|----------------------------|
| 1. Already focused | Target is the current tab of the front window | No AppleScript action | Non-interfering |
| 2. Same window | Target is a background tab within the front window | `set current tab of window N to tab T` | Passively interfering, transitively authorized by the invoking command's semantics (no new opt-in flag required) |
| 3. Same Space | Target is in a different window sharing the caller's current macOS Space | Activate that window and, if needed, switch its current tab | Passively interfering; stderr warning SHALL be emitted |
| 4. Cross-Space | Target is in a window on a different macOS Space | Do NOT raise across Space; fall back to opening a new tab in the current Space | Non-interfering (the cross-Space target is left undisturbed) |

Space membership SHALL be detected via the CGWindow API (`kCGWindowWorkspace` or equivalent). If Space detection fails due to missing permissions, the system SHALL default to the same-Space behavior (layer 3, raise window) rather than introduce unauthorized cross-Space interference, and SHALL emit a stderr note that Space detection was unavailable.

This gradient SHALL apply uniformly to every command that performs focus-existing, not only `open`.

#### Scenario: Layer 1 — target already focused is a no-op

- **WHEN** user runs `safari-browser open https://example.com/` and the front window's current tab is already at `https://example.com/`
- **THEN** the system SHALL NOT issue any AppleScript navigation or window-activation command
- **AND** stdout/stderr SHALL contain no interference warnings

#### Scenario: Layer 2 — same-window tab switch is passive and silent

- **WHEN** user runs `safari-browser open https://b.example/` and the front window has two tabs (`a.example` current, `b.example` background)
- **THEN** the system SHALL switch the front window's current tab to the `b.example` tab
- **AND** SHALL NOT emit a stderr interference warning
- **AND** the user's typing in other applications SHALL NOT be disrupted

#### Scenario: Layer 3 — cross-window raise emits stderr warning

- **WHEN** the target tab exists in window 2 and window 1 is currently frontmost, both in the same Space
- **THEN** the system SHALL activate window 2 (bringing it to front)
- **AND** SHALL switch window 2's current tab to the target tab if the target is not already current within window 2
- **AND** stderr SHALL contain a warning mentioning that a background window was raised

#### Scenario: Layer 4 — cross-Space target triggers new-tab fallback

- **WHEN** the target tab exists in window 3 which is on macOS Space B
- **AND** the caller's current context is on Space A
- **AND** CGWindow API successfully reports the window is on Space B
- **THEN** the system SHALL NOT raise window 3 or switch Space
- **AND** SHALL open a new tab in the front window of Space A navigated to the target URL
- **AND** stderr SHALL contain a note indicating an existing tab exists on another Space and was left undisturbed

#### Scenario: Space detection failure falls back to layer 3

- **WHEN** the CGWindow API call to determine a window's Space membership fails (e.g., screen recording permission denied)
- **AND** a focus-existing operation needs to classify a cross-window target
- **THEN** the system SHALL proceed as if the target is in the same Space (layer 3: raise window)
- **AND** stderr SHALL contain a note indicating Space detection was unavailable and suggesting the screen recording permission

#### Scenario: Gradient applies to any focus-existing invocation

- **WHEN** a future command beyond `open` invokes focus-existing semantics (e.g., a hypothetical `focus` subcommand)
- **THEN** its interference classification SHALL follow the same spatial gradient defined here
- **AND** SHALL NOT redefine the gradient behavior locally
