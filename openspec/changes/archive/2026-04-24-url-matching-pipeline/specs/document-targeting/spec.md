## ADDED Requirements

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

## MODIFIED Requirements

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
