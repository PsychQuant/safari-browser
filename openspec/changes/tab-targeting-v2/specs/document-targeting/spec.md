## ADDED Requirements

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

### Requirement: First-match opt-in flag

The CLI SHALL accept a new flag `--first-match` that, when combined with `--url <substring>`, permits the resolver to select the first matching tab when multiple tabs match the substring, rather than failing with `ambiguousWindowMatch`. When `--first-match` is active and multiple matches exist, the command SHALL emit a stderr warning enumerating every match and indicating which was selected.

Without `--first-match`, all path-independent targeted commands (both JS-path and Native-path) SHALL fail-closed on multi-match, per the unified fail-closed policy defined below.

#### Scenario: --first-match selects deterministically

- **WHEN** Safari has two tabs matching `--url plaud`
- **AND** user runs `safari-browser js --url plaud --first-match "document.title"`
- **THEN** the command SHALL select the tab with the lower (window, tab-in-window) ordering
- **AND** SHALL emit a stderr warning listing both matches and indicating which was chosen

#### Scenario: Without --first-match multi-match still fails

- **WHEN** the same two matching tabs exist and user runs `safari-browser js --url plaud "document.title"` (no `--first-match`)
- **THEN** the command SHALL exit with `ambiguousWindowMatch` listing both matches

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

### Requirement: Unified urlContains fail-closed policy

All target-resolution paths in safari-browser (including what was previously implemented via the JS-path AppleScript expression `first document whose URL contains "..."`) SHALL apply fail-closed semantics when `--url <substring>` matches more than one tab. The implementation SHALL enumerate all tabs, count matches, and throw `ambiguousWindowMatch` with the full match list when count > 1.

The policy SHALL hold regardless of which subcommand (`js`, `open`, `get`, `wait`, `storage`, `snapshot`, `upload`, `close`, etc.) invokes resolution. Exception: when `--first-match` is supplied, the command SHALL select the first match with a stderr warning.

#### Scenario: js command fails closed on multi-match --url

- **WHEN** Safari has two tabs matching `--url plaud` and user runs `safari-browser js --url plaud "1 + 1"`
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
