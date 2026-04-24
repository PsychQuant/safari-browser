# document-targeting Specification

## Purpose

TBD - created by archiving change 'multi-document-targeting'. Update Purpose after archive.

## Requirements

### Requirement: Target document selection via CLI flags

The system SHALL provide a set of global CLI flags that select the target Safari document for any subsequent subcommand. The flags fall into three mutually exclusive groups:

1. **URL-matching flags** (all mutually exclusive with each other and with the remaining groups): `--url <substring>`, `--url-exact <url>`, `--url-endswith <suffix>`, `--url-regex <pattern>`.
2. **Index-based flags** (mutually exclusive with each other and with group 1): `--window <n>`, `--tab <n>`, `--document <n>`.
3. **Composite same-URL escape hatch**: `--window <n>` combined with `--tab-in-window <m>` targets the `m`-th tab of window `n`. This composite SHALL be rejected if paired with any flag from group 1, or with `--tab` or `--document`.

If no target flag is provided, the system SHALL default to the first document in Safari's document collection (`document 1`). If more than one flag is supplied in a way that violates the exclusivity rules, the system SHALL reject the invocation with a validation error before executing the subcommand.

#### Scenario: Default targeting with no flags

- **WHEN** user runs `safari-browser get url` with no target flag
- **THEN** the system resolves the target to `document 1` of Safari
- **AND** the command returns the URL of that document

#### Scenario: URL substring targeting

- **WHEN** user runs `safari-browser get --url "plaud" url`
- **AND** Safari has multiple documents, one of which has `https://web.plaud.ai/` as its URL
- **THEN** the system resolves the target to the first document whose URL contains the substring `plaud`
- **AND** the command returns `https://web.plaud.ai/`

#### Scenario: URL exact targeting

- **WHEN** user runs `safari-browser get --url-exact "https://web.plaud.ai/" url`
- **AND** Safari has a document whose URL equals `https://web.plaud.ai/` exactly
- **THEN** the system resolves the target to that document
- **AND** the command returns `https://web.plaud.ai/`

#### Scenario: URL endsWith targeting

- **WHEN** user runs `safari-browser get --url-endswith "/play" url`
- **AND** Safari has a document whose URL ends with `/play`
- **THEN** the system resolves the target to that document
- **AND** the command returns the full URL of that document

#### Scenario: URL regex targeting

- **WHEN** user runs `safari-browser get --url-regex "lesson/[a-f0-9-]+$" url`
- **AND** Safari has a document whose URL matches the regex
- **THEN** the system resolves the target to that document
- **AND** the command returns the full URL

#### Scenario: Window index targeting

- **WHEN** user runs `safari-browser get --window 2 url`
- **AND** Safari has at least two windows
- **THEN** the system resolves the target to the document of the second window (1-indexed)
- **AND** the command returns that window's document URL

#### Scenario: Document index targeting

- **WHEN** user runs `safari-browser get --document 3 url`
- **AND** Safari has at least three documents in its document collection
- **THEN** the system resolves the target to `document 3`
- **AND** the command returns that document's URL

#### Scenario: Tab alias for document

- **WHEN** user runs `safari-browser get --tab 2 url`
- **THEN** the system treats `--tab 2` identically to `--document 2`
- **AND** the command returns the URL of `document 2`

#### Scenario: Mutually exclusive URL flags rejected

- **WHEN** user runs `safari-browser get url --url plaud --url-endswith /play`
- **THEN** the system SHALL print a usage error identifying the conflicting URL flags
- **AND** the system SHALL exit with a non-zero status before invoking any Safari operation

#### Scenario: URL flag combined with window index rejected

- **WHEN** user runs `safari-browser get url --url plaud --window 2`
- **THEN** the system SHALL print a usage error identifying the mutually exclusive flags
- **AND** the system SHALL exit with a non-zero status before invoking any Safari operation


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: Document reference resolution

The system SHALL expose a `TargetDocument` value type with exactly five cases (`frontWindow`, `windowIndex(Int)`, `urlMatch(UrlMatcher)`, `documentIndex(Int)`, `windowTab(window: Int, tabInWindow: Int)`) and a resolution helper that maps each case to a valid AppleScript document reference expression or delegates to the native-path resolver. The reference expression MUST be safe to interpolate inside `tell application "Safari" to ...` without additional escaping beyond the existing `escapedForAppleScript` string helper.

The `.urlMatch` case SHALL delegate URL matching to the `UrlMatcher` value's own matching function; the AppleScript reference path SHALL NOT attempt to express matcher variance via the AppleScript term `first document whose URL contains "..."` — instead it SHALL enumerate tabs via `SafariBridge.listAllWindows()`, apply `UrlMatcher.matches` in Swift, and dispatch to the resolved `(windowIndex, tabInWindow)` pair. This preserves the unified fail-closed policy uniformly across all matcher cases.

#### Scenario: Front window resolves to document 1

- **WHEN** `TargetDocument.frontWindow` is resolved
- **THEN** the returned AppleScript reference SHALL be `document 1`

#### Scenario: Window index resolves to document of window n

- **WHEN** `TargetDocument.windowIndex(2)` is resolved
- **THEN** the returned AppleScript reference SHALL be `document of window 2`

#### Scenario: urlMatch contains resolves via enumeration

- **WHEN** `TargetDocument.urlMatch(.contains("plaud"))` is resolved
- **AND** Safari has exactly one tab whose URL contains `plaud`
- **THEN** the resolver SHALL enumerate windows via `listAllWindows`
- **AND** SHALL dispatch to the matching `(windowIndex, tabInWindow)` pair
- **AND** the final AppleScript reference SHALL target that specific tab

#### Scenario: urlMatch endsWith resolves via enumeration

- **WHEN** `TargetDocument.urlMatch(.endsWith("/play"))` is resolved
- **AND** Safari has exactly one tab whose URL ends with `/play`
- **THEN** the resolver SHALL enumerate windows via `listAllWindows`
- **AND** SHALL dispatch to the matching `(windowIndex, tabInWindow)` pair

#### Scenario: Document index resolves to document n

- **WHEN** `TargetDocument.documentIndex(3)` is resolved
- **THEN** the returned AppleScript reference SHALL be `document 3`

#### Scenario: windowTab resolves to tab of window

- **WHEN** `TargetDocument.windowTab(window: 1, tabInWindow: 2)` is resolved
- **THEN** the returned AppleScript reference SHALL target `tab 2 of window 1`


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: Read-only query bypasses window-level modal blocks

The system SHALL route read-only document queries (getting URL, title, text, source, executing JavaScript) through document-scoped AppleScript references (`document N`), not window-scoped references (`current tab of front window`). This bypass SHALL remain effective even when Safari's front window has an active modal file dialog sheet that blocks window-scoped AppleScript dispatch.

#### Scenario: Get URL succeeds while front window shows modal sheet

- **WHEN** Safari's front window currently displays a modal file dialog sheet
- **AND** user runs `safari-browser get url`
- **THEN** the command SHALL return the URL within the default process timeout (30 s)
- **AND** the command SHALL NOT hang waiting for the sheet to be dismissed

#### Scenario: Read-only query respects target override during modal block

- **WHEN** Safari has two documents and the front window has a modal sheet open
- **AND** user runs `safari-browser get --document 2 url`
- **THEN** the command returns document 2's URL without waiting for the modal


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Document not found surfaces discoverable error

When the user supplies a target flag that does not match any document (URL substring not found, window index out of range, document index out of range), the system SHALL throw `SafariBrowserError.documentNotFound(pattern: String, availableDocuments: [String])`. The error description MUST list the URLs of all currently available documents so the user can correct their target without running an additional command.

#### Scenario: URL substring with no matching document

- **WHEN** Safari has documents `[https://web.plaud.ai/, https://platform.claude.com/]`
- **AND** user runs `safari-browser get --url xyz url`
- **THEN** the system SHALL throw `documentNotFound` with `pattern: "xyz"` and `availableDocuments` listing both URLs
- **AND** the error description SHALL contain both `https://web.plaud.ai/` and `https://platform.claude.com/`

#### Scenario: Window index out of range

- **WHEN** Safari has one window
- **AND** user runs `safari-browser get --window 5 url`
- **THEN** the system SHALL throw `documentNotFound` identifying the requested window index
- **AND** the error description SHALL list available windows


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
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

---
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

---
### Requirement: Tab auto-switch before keystroke dispatch

When the resolver determines that a target document resides in a non-current tab of its owning window, the system SHALL switch that window's active tab to the target before dispatching any keystroke. The tab switch SHALL use AppleScript `set current tab of window N to tab T`. The tab switch SHALL be classified as a passively interfering side effect transitively authorized by the `--native` or `--allow-hid` opt-in flag.

**Concurrent modification window** (#26 verify P1-3): The native-path workflow spans multiple independent `osascript` sessions — `listAllWindows` (resolver enumeration), `performTabSwitchIfNeeded` (optional tab switch), `getCurrentURL` / `ensureSystemEventsLive` (preflight), and the main upload / PDF / close keystroke dispatch. Safari window state MAY change between sessions (user closes a window, another AppleScript client reorders tabs); when the target window or tab disappears mid-workflow, downstream AppleScript surfaces the resulting runtime error rather than the user-friendly `documentNotFound` translation. Callers that cannot tolerate this race SHALL snapshot Safari state before invocation and validate it afterward; future hardening MAY consolidate the sessions behind a single `osascript` to close the gap.

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

---
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

---
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

<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Composite targeting flag --tab-in-window

The CLI SHALL accept a new flag `--tab-in-window N` (1-indexed) that selects a specific tab within a Safari window. This flag SHALL be valid only when paired with `--window M`; supplying `--tab-in-window` without `--window` SHALL produce a validation error before any AppleScript executes.

When both `--window M` and `--tab-in-window N` are supplied, the resolver SHALL target the Nth tab of the Mth window as enumerated by `tabs of windows`. This provides a structured addressing mechanism for tabs that share an identical URL and cannot be disambiguated through `--url <substring>`.

`--tab-in-window` SHALL be mutually exclusive with `--url`, `--tab`, and `--document` (the existing exclusivity contract extends to this new flag).

#### Scenario: --tab-in-window requires --window

- **WHEN** user runs `safari-browser get url --tab-in-window 2` without supplying `--window`
- **THEN** the CLI SHALL exit with a validation error stating that `--tab-in-window` requires `--window`
- **AND** no AppleScript SHALL execute

#### Scenario: --window + --tab-in-window resolves correctly

- **WHEN** Safari has window 1 with three tabs (`a`, `b`, `c` in order) and user runs `safari-browser get url --window 1 --tab-in-window 2`
- **THEN** the command SHALL return the URL of tab `b`

#### Scenario: Disambiguate same-URL tabs via composite flag

- **WHEN** window 1 contains two tabs both at `https://web.plaud.ai/` (tab indices 1 and 2)
- **AND** user runs `safari-browser click "button.upload" --window 1 --tab-in-window 2`
- **THEN** the command SHALL act on the second tab specifically
- **AND** the first tab SHALL remain unaffected


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: First-match opt-in flag

The CLI SHALL accept a flag `--first-match` that, when combined with any URL-matching flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`), permits the resolver to select the first matching tab when multiple tabs match, rather than failing with `ambiguousWindowMatch`. When `--first-match` is active and multiple matches exist, the command SHALL emit a stderr warning enumerating every match and indicating which was selected. Without `--first-match`, all path-independent targeted commands (both read-path and native-path) SHALL fail-closed on multi-match per the unified fail-closed policy.

The `--first-match` flag supplied without any URL-matching flag SHALL be accepted as a no-op (not an error), for forward compatibility with scripts that supply the flag unconditionally.

#### Scenario: --first-match selects deterministically with --url

- **WHEN** Safari has two tabs matching `--url plaud`
- **AND** user runs `safari-browser js --url plaud --first-match "document.title"`
- **THEN** the command SHALL select the tab with the lower `(window, tab-in-window)` ordering
- **AND** SHALL emit a stderr warning listing both matches and indicating which was chosen

#### Scenario: --first-match applies to --url-endswith

- **WHEN** Safari has two tabs both ending with `/play`
- **AND** user runs `safari-browser js --url-endswith /play --first-match "document.title"`
- **THEN** the command SHALL select the tab with the lower `(window, tab-in-window)` ordering
- **AND** SHALL emit a stderr warning listing both matches

#### Scenario: --first-match applies to --url-regex

- **WHEN** Safari has two tabs matching regex `lesson/[a-f0-9-]+$`
- **AND** user runs `safari-browser js --url-regex "lesson/[a-f0-9-]+$" --first-match "document.title"`
- **THEN** the command SHALL select the tab with the lower `(window, tab-in-window)` ordering
- **AND** SHALL emit a stderr warning listing both matches

#### Scenario: Without --first-match multi-match still fails

- **WHEN** the same two matching tabs exist and user runs `safari-browser js --url plaud "document.title"` (no `--first-match`)
- **THEN** the command SHALL exit with `ambiguousWindowMatch` listing both matches

#### Scenario: --first-match without any URL flag is a no-op

- **WHEN** user runs `safari-browser js --first-match "1 + 1"` (no URL-matching flag)
- **THEN** the command SHALL NOT fail validation
- **AND** SHALL execute against the default target (`document 1`)


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: Replace-tab opt-in flag for open

The CLI SHALL accept a new flag `--replace-tab` on the `open` subcommand that forces the legacy behavior: navigate the front window's current tab to the requested URL via `do JavaScript window.location.href=...`, ignoring any existing tab that already has that URL.

Without `--replace-tab`, the default behavior of `open` SHALL be focus-existing (see `navigation` spec). `--replace-tab` SHALL be mutually exclusive with `--new-tab` and `--new-window`.

#### Scenario: --replace-tab navigates front tab

- **WHEN** Safari has an existing tab at `https://web.plaud.ai/` in a background window and user runs `safari-browser open --replace-tab https://web.plaud.ai/`
- **THEN** the current tab of the front window SHALL be navigated to `https://web.plaud.ai/`
- **AND** the existing background tab SHALL NOT be focused or raised

#### Scenario: --replace-tab conflicts with --new-tab

- **WHEN** user runs `safari-browser open --replace-tab --new-tab https://example.com`
- **THEN** the CLI SHALL exit with a validation error stating that `--replace-tab`, `--new-tab`, and `--new-window` are mutually exclusive


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: --tab alias deprecation

The existing `--tab N` flag, which currently aliases to `--document N` (selecting the Nth document in the document collection), SHALL emit a stderr deprecation warning on every invocation when used. The warning text SHALL indicate the flag will be removed in v3.0 and suggest the replacement: use `--document N` to preserve current semantics, or `--tab-in-window N --window M` for window-scoped tab addressing.

The flag SHALL continue to accept its current semantics during the deprecation period to preserve script compatibility.

#### Scenario: --tab emits deprecation warning

- **WHEN** user runs `safari-browser get url --tab 2`
- **THEN** stderr SHALL contain a deprecation warning mentioning v3.0 removal, `--document`, and `--tab-in-window` as replacements
- **AND** the command SHALL still resolve `--tab 2` to the 2nd document and execute normally

#### Scenario: --tab warning does not pollute stdout

- **WHEN** a script parses stdout from `safari-browser get url --tab 2`
- **THEN** stdout SHALL contain only the URL value, not the deprecation warning
- **AND** the warning SHALL appear only on stderr


<!-- @trace
source: tab-targeting-v2
updated: 2026-04-18
code:
-->

---
### Requirement: Unified urlContains fail-closed policy

All target-resolution paths in safari-browser SHALL apply fail-closed semantics when a URL-matching flag admits more than one tab, regardless of matcher kind (`contains`, `exact`, `endsWith`, `regex`). The implementation SHALL enumerate all tabs, apply `UrlMatcher.matches` to each URL, count matches, and throw `ambiguousWindowMatch` with the full match list when count > 1. The `.exact` matcher case SHALL hold the same fail-closed contract even though URL equality in practice yields at most one match — duplicate tabs with identical URLs are legal in Safari and MUST be handled uniformly.

The policy SHALL hold regardless of which subcommand (`js`, `open`, `get`, `wait`, `storage`, `snapshot`, `upload`, `close`, etc.) invokes resolution. Exception: when `--first-match` is supplied, the command SHALL select the first match with a stderr warning.

#### Scenario: js command fails closed on multi-match --url

- **WHEN** Safari has two tabs matching `--url plaud` and user runs `safari-browser js --url plaud "1 + 1"`
- **THEN** the command SHALL exit with `ambiguousWindowMatch`
- **AND** SHALL NOT execute the JavaScript on either tab

#### Scenario: js command fails closed on multi-match --url-endswith

- **WHEN** Safari has two tabs whose URLs both end with `/play` and user runs `safari-browser js --url-endswith /play "1 + 1"`
- **THEN** the command SHALL exit with `ambiguousWindowMatch`
- **AND** SHALL NOT execute the JavaScript on either tab

#### Scenario: js command fails closed on duplicate --url-exact

- **WHEN** Safari has two tabs whose URLs are both exactly `https://example.com/` and user runs `safari-browser js --url-exact "https://example.com/" "1 + 1"`
- **THEN** the command SHALL exit with `ambiguousWindowMatch`
- **AND** SHALL NOT execute the JavaScript on either tab

#### Scenario: open command fails closed on multi-match --url

- **WHEN** Safari has two tabs matching `--url plaud` and user runs `safari-browser open --url plaud https://plaud.ai/new`
- **THEN** the command SHALL exit with `ambiguousWindowMatch`
- **AND** SHALL NOT navigate either matching tab

#### Scenario: get url fails closed on multi-match --url

- **WHEN** Safari has two tabs matching `--url plaud` and user runs `safari-browser get url --url plaud`
- **THEN** the command SHALL exit with `ambiguousWindowMatch`
- **AND** stdout SHALL be empty


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: UrlMatcher sum-type encapsulates URL matching modes

The system SHALL expose a `UrlMatcher` value type as a sum-type with exactly four cases: `contains(String)`, `exact(String)`, `endsWith(String)`, and `regex(NSRegularExpression)`. The type SHALL conform to `Sendable` and `Equatable`. The type SHALL expose a pure matching function `matches(_ url: String) -> Bool` that returns true when the matcher admits the given URL string. The matching function SHALL NOT perform URL canonicalization (no trailing-slash handling, no percent-encoding normalization, no host case folding) — it operates on the raw string as Safari returns it from `URL of tab`.

#### Scenario: contains matches when pattern is substring

- **WHEN** `UrlMatcher.contains("plaud").matches("https://web.plaud.ai/")` is evaluated
- **THEN** the result SHALL be `true`

#### Scenario: exact requires full string equality

- **WHEN** `UrlMatcher.exact("https://web.plaud.ai/").matches("https://web.plaud.ai")` is evaluated (trailing slash differs)
- **THEN** the result SHALL be `false`

##### Example: exact boundary cases

| Input URL | Matcher | Expected |
| --------- | ------- | -------- |
| `https://example.com/` | `.exact("https://example.com/")` | `true` |
| `https://example.com/` | `.exact("https://example.com")` | `false` (trailing slash differs) |
| `https://example.com/?q=1` | `.exact("https://example.com/")` | `false` (query differs) |
| `https://Example.com/` | `.exact("https://example.com/")` | `false` (host case differs) |

#### Scenario: endsWith matches when URL ends with suffix

- **WHEN** `UrlMatcher.endsWith("/play").matches("https://vod.edupsy.tw/course/a/lesson/b/video/c/auth/d/play")` is evaluated
- **THEN** the result SHALL be `true`

#### Scenario: endsWith returns false when suffix not at end

- **WHEN** `UrlMatcher.endsWith("/play").matches("https://example.com/play/next")` is evaluated
- **THEN** the result SHALL be `false`

#### Scenario: regex uses unanchored matching by default

- **WHEN** `UrlMatcher.regex(NSRegularExpression(pattern: "plaud", options: [])).matches("https://web.plaud.ai/")` is evaluated
- **THEN** the result SHALL be `true` because the unanchored pattern admits the substring

#### Scenario: regex respects explicit anchors

- **WHEN** `UrlMatcher.regex(NSRegularExpression(pattern: "^https://plaud\\.ai/$", options: [])).matches("https://web.plaud.ai/")` is evaluated
- **THEN** the result SHALL be `false` because the anchored pattern requires exact string match


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: Precise URL matching CLI flags

The CLI SHALL accept three additional URL-targeting flags as peers of `--url`: `--url-exact <url>`, `--url-endswith <suffix>`, and `--url-regex <pattern>`. The four URL flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`) SHALL be mutually exclusive with each other. Each flag SHALL map to the corresponding `UrlMatcher` case:

| CLI flag | UrlMatcher case |
| -------- | --------------- |
| `--url <substring>` | `.contains(substring)` |
| `--url-exact <url>` | `.exact(url)` |
| `--url-endswith <suffix>` | `.endsWith(suffix)` |
| `--url-regex <pattern>` | `.regex(compiled_pattern)` |

The `--url-regex <pattern>` flag SHALL compile the pattern as `NSRegularExpression` with default options (case-sensitive, unanchored). If compilation fails, the command SHALL reject the invocation with a validation error before executing any Safari operation. The validation error SHALL include the underlying `NSRegularExpression` error description.

The `--url-endswith ""` invocation (empty suffix) SHALL be rejected with a validation error stating that an empty suffix expresses no intent.

#### Scenario: url-exact matches unique tab in hierarchical URL set

- **WHEN** Safari has two tabs whose URLs are `https://x/lesson/1` and `https://x/lesson/1/play`
- **AND** user runs `safari-browser get url --url-exact "https://x/lesson/1"`
- **THEN** the command SHALL resolve to the first tab and print `https://x/lesson/1`
- **AND** SHALL NOT match the prefix-parent tab

#### Scenario: url-endswith disambiguates hierarchical URLs by suffix

- **WHEN** Safari has two tabs whose URLs are `https://x/lesson/1` and `https://x/lesson/1/play`
- **AND** user runs `safari-browser get url --url-endswith "/lesson/1"`
- **THEN** the command SHALL resolve to the first tab and print `https://x/lesson/1`

#### Scenario: url-regex rejects invalid pattern at validation time

- **WHEN** user runs `safari-browser get url --url-regex "["` (unbalanced bracket)
- **THEN** the system SHALL print a validation error identifying the compile failure
- **AND** SHALL exit with non-zero status before invoking any Safari operation

#### Scenario: Multiple URL flags rejected as mutually exclusive

- **WHEN** user runs `safari-browser get url --url plaud --url-endswith /play`
- **THEN** the system SHALL print a validation error listing the conflicting URL flags
- **AND** SHALL exit with non-zero status before invoking any Safari operation

#### Scenario: Empty endsWith suffix rejected

- **WHEN** user runs `safari-browser get url --url-endswith ""`
- **THEN** the system SHALL print a validation error stating that `--url-endswith` requires a non-empty suffix
- **AND** SHALL exit with non-zero status before invoking any Safari operation


<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->

---
### Requirement: First-match flag propagates through read-path resolver

The system SHALL propagate the `--first-match` intent from `TargetOptions` through the read-path resolver chain so that every read-path subcommand (`js`, `get`, `snapshot`, `storage`, `wait`, `click`, `fill`, `upload --js`) honors `--first-match` semantics identically to native-path subcommands (`close`, `screenshot`, `pdf`, `upload --native`). Specifically:

- `SafariBridge.resolveToAppleScript(_:firstMatch:warnWriter:)` SHALL accept `firstMatch: Bool` (default `false`) and `warnWriter: ((String) -> Void)?` (default `nil`), and SHALL forward both parameters to `resolveNativeTarget` when the target case requires resolver enumeration.
- All read-path bridge entry points that dispatch through `resolveToAppleScript` (including `doJavaScript`, `doJavaScriptLarge`, `getCurrentURL`, `getCurrentTitle`, and any future read-path entry point) SHALL expose matching `firstMatch` / `warnWriter` parameters with the same defaults.
- Every command that composes `@OptionGroup var target: TargetOptions` SHALL read `target.firstMatch` at run time and pass it to the bridge entry point it invokes.

The system SHALL expose a helper on `TargetOptions` that produces a `(target: TargetDocument, firstMatch: Bool, warnWriter: (String) -> Void)` tuple so command wiring is uniform across the read-path surface.

#### Scenario: js command honors --first-match against multi-match URL

- **WHEN** Safari has two tabs whose URLs both contain `lesson/7baa5578`
- **AND** user runs `safari-browser js --url "lesson/7baa5578" --first-match "document.title"`
- **THEN** the command SHALL select the tab with the lower `(window, tab-in-window)` ordering
- **AND** SHALL print the selected tab's `document.title` to stdout
- **AND** SHALL emit a stderr warning listing every matching tab and naming the selected one
- **AND** SHALL exit with status `0`

#### Scenario: get url command honors --first-match against multi-match URL

- **WHEN** Safari has two tabs whose URLs both contain `plaud`
- **AND** user runs `safari-browser get url --url plaud --first-match`
- **THEN** the command SHALL print the URL of the first matching tab to stdout
- **AND** SHALL emit a stderr warning listing every match
- **AND** SHALL exit with status `0`

#### Scenario: snapshot command honors --first-match against multi-match URL

- **WHEN** Safari has two tabs whose URLs both contain `plaud`
- **AND** user runs `safari-browser snapshot --url plaud --first-match`
- **THEN** the command SHALL produce the snapshot of the first matching tab
- **AND** SHALL emit a stderr warning listing every match
- **AND** SHALL exit with status `0`

<!-- @trace
source: url-matching-pipeline
updated: 2026-04-24
code:
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonDispatch.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Tests/SafariBrowserTests/SafariBridgeTargetTests.swift
  - Sources/SafariBrowser/Commands/MouseCommand.swift
  - Sources/SafariBrowser/Commands/OpenCommand.swift
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/PressCommand.swift
  - Sources/SafariBrowser/Commands/WaitCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/UrlMatcher.swift
  - Tests/SafariBrowserTests/WindowIndexResolverTests.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/SaveImageCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonRouter.swift
  - Tests/SafariBrowserTests/FirstMatchTests.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Tests/SafariBrowserTests/ResolverConvergenceTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/Commands/FindCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - CHANGELOG.md
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/ReloadCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/TargetOptions.swift
  - Sources/SafariBrowser/Commands/StorageCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/Commands/ScrollCommand.swift
  - Tests/SafariBrowserTests/ResolveNativeTargetPlumbingTests.swift
  - Sources/SafariBrowser/Commands/BackCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/ForwardCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/ErrorsCommand.swift
  - Sources/SafariBrowser/Daemon/DaemonServeLoop.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Tests/SafariBrowserTests/DaemonAppleScriptHandlerTests.swift
  - Tests/Fixtures/save-image-test.html
  - Sources/SafariBrowser/Commands/CloseCommand.swift
  - Tests/SafariBrowserTests/UrlMatcherTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/Issue28RegressionTests.swift
  - Tests/SafariBrowserTests/TargetOptionsTests.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Tests/e2e-test.sh
-->
