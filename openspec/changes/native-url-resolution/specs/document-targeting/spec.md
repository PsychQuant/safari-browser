## ADDED Requirements

### Requirement: Native path URL resolution to window index

The system SHALL resolve `TargetOptions` into a physical Safari window index before dispatching any keystroke-based or window-scoped AppleScript operation. The resolver SHALL accept all four targeting flags (`--url`, `--window`, `--tab`, `--document`) for window-only primitives (`upload --native`, `upload --allow-hid`, `close`, `pdf`, `screenshot`) and map them to a window index using the following rules:

1. `--window N` (or no flag → front window): return N directly (or 1 for front window).
2. `--document N` / `--tab N`: map the Nth entry in Safari's document collection to the physical window that currently owns that document, and return that window's index.
3. `--url <pattern>`: enumerate all Safari documents in window order, select the window whose document URL contains `<pattern>` as a substring, and return that window's index.

The resolver SHALL execute entirely within a single Swift process invocation (no shell subprocess chaining), and SHALL be stateless across resolver calls within the same process (no caching of prior results).

#### Scenario: Resolver accepts --url for native upload

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/` and one showing `https://github.com/`
- **AND** user runs `safari-browser upload --native "input[type=file]" "/tmp/audio.mp3" --url plaud`
- **THEN** the system SHALL resolve `--url plaud` to the window index of the plaud window
- **AND** SHALL dispatch the native file-dialog keystroke sequence to that resolved window
- **AND** SHALL NOT reject the invocation at validation time

#### Scenario: Resolver accepts --window for backward compatibility

- **WHEN** user runs `safari-browser upload --native "input[type=file]" "/tmp/file.mp3" --window 2`
- **THEN** the system SHALL pass window index 2 through unchanged to the keystroke dispatch layer
- **AND** the command SHALL behave identically to pre-change `--window 2` behavior (same raise, same keystroke path)

#### Scenario: Resolver accepts --document for native path

- **WHEN** Safari has three documents spread across two windows
- **AND** user runs `safari-browser screenshot --document 3 /tmp/shot.png`
- **THEN** the system SHALL identify which physical window owns the third document in Safari's document collection
- **AND** SHALL dispatch the screenshot capture against that window

### Requirement: Window ambiguity surfaces deterministic error

When a `--url <pattern>` targeting flag matches more than one window's document URL, the system SHALL reject the invocation with `SafariBrowserError.ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, url: String)])`. The error description MUST list every matching window index and its URL so the user can correct their target without running an additional command. The system SHALL NOT silently select the first match.

#### Scenario: Multiple windows match URL substring

- **WHEN** Safari has three windows showing `https://web.plaud.ai/file/a`, `https://web.plaud.ai/file/b`, and `https://github.com/`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL throw `ambiguousWindowMatch` with `pattern: "plaud"` and `matches` containing both plaud window indices and URLs
- **AND** the error description SHALL contain both `https://web.plaud.ai/file/a` and `https://web.plaud.ai/file/b`
- **AND** the system SHALL NOT perform any keystroke or window raise

#### Scenario: Specific substring resolves ambiguity

- **WHEN** Safari has three windows as above
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url "plaud.ai/file/a"`
- **THEN** the system SHALL resolve to the window showing `https://web.plaud.ai/file/a` unambiguously
- **AND** SHALL proceed with the keystroke dispatch

### Requirement: Tab auto-switch before keystroke dispatch

When the resolver determines that a target document resides in a non-current tab of its owning window, the system SHALL switch that window's active tab to the target before dispatching any keystroke. The tab switch SHALL use AppleScript `set current tab of window N to tab T` within the same AppleScript session as the subsequent raise and keystroke. The tab switch SHALL be classified as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag.

#### Scenario: Target URL in background tab of a window

- **WHEN** Safari window 1 has three tabs: `https://github.com/` (current), `https://web.plaud.ai/` (background), `https://news.ycombinator.com/` (background)
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL switch window 1's current tab to the plaud tab
- **AND** SHALL raise window 1 to the front
- **AND** SHALL dispatch the keystroke path against the now-active plaud tab

#### Scenario: Target URL already in current tab

- **WHEN** Safari window 1's current tab is already `https://web.plaud.ai/`
- **AND** user runs `safari-browser upload --native "input" "/tmp/f.mp3" --url plaud`
- **THEN** the system SHALL NOT issue a tab switch AppleScript command
- **AND** SHALL proceed directly to raise and keystroke

### Requirement: WindowOnlyTargetOptions removal

The system SHALL expose a single `TargetOptions` parser struct to all subcommands, including those previously restricted to `WindowOnlyTargetOptions`. The `WindowOnlyTargetOptions` struct SHALL be removed. Commands that were previously window-only (`close`, `screenshot`, `pdf`, `upload --native`, `upload --allow-hid`) SHALL accept the full four-flag targeting surface through `TargetOptions` and resolve to a window index via the native path resolver.

#### Scenario: close command accepts --url

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/`
- **AND** user runs `safari-browser close --url plaud`
- **THEN** the system SHALL resolve `--url plaud` to the plaud window's index
- **AND** SHALL close that window
- **AND** SHALL NOT reject the invocation with "WindowOnly only supports --window"

#### Scenario: pdf command accepts --document

- **WHEN** Safari has two documents across two windows
- **AND** user runs `safari-browser pdf --document 2 --allow-hid /tmp/page.pdf`
- **THEN** the system SHALL resolve document 2 to its owning window
- **AND** SHALL raise that window and dispatch the PDF dialog keystroke path

## MODIFIED Requirements

### Requirement: Backward compatibility with existing scripts

The system SHALL NOT change behavior for invocations that omit all target flags, beyond switching the default read-only query from `current tab of front window` to `document 1`. In single-window Safari usage, `document 1` MUST be equivalent to `current tab of front window`, so existing scripts that assume the legacy target SHALL continue to work without modification. When invocations supply `--url`, `--window`, `--tab`, or `--document`, window-scoped and keystroke-based operations SHALL use the native path resolver to map the target to a window index and then perform the raise / tab-switch / keystroke sequence on that resolved window.

#### Scenario: Single-window default targeting matches legacy

- **WHEN** Safari has exactly one window with one tab
- **AND** user runs `safari-browser get url` without any target flag
- **THEN** the returned URL MUST equal the URL of `current tab of front window`

#### Scenario: Keystroke operations preserve front-window semantics when no flag given

- **WHEN** user runs `safari-browser upload --native <input> <file>` without any target flag
- **THEN** keystroke-driven operations SHALL continue to target `front window`
- **AND** SHALL NOT be redirected to a non-focused document

#### Scenario: Keystroke operations resolve target when flag given

- **WHEN** user runs `safari-browser upload --native <input> <file> --url plaud` and Safari has a plaud window that is not the front window
- **THEN** the system SHALL resolve the plaud window index
- **AND** SHALL raise that window (switching tab if the plaud document is in a background tab of that window)
- **AND** SHALL dispatch the keystroke path against the resolved, now-frontmost plaud window
