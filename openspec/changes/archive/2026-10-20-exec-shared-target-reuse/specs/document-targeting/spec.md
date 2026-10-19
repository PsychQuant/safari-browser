## MODIFIED Requirements

### Requirement: Unified urlContains fail-closed policy

All target-resolution paths in safari-browser SHALL apply fail-closed semantics when a URL-matching flag admits more than one tab, regardless of matcher kind (`contains`, `exact`, `endsWith`, `regex`). The implementation SHALL enumerate all tabs, apply `UrlMatcher.matches` to each URL, count matches, and throw `ambiguousWindowMatch` with the full match list when count > 1. The `.exact` matcher case SHALL hold the same fail-closed contract even though URL equality in practice yields at most one match — duplicate tabs with identical URLs are legal in Safari and MUST be handled uniformly.

The policy SHALL hold regardless of which subcommand (`js`, `open`, `get`, `wait`, `storage`, `snapshot`, `upload`, `close`, etc.) invokes resolution. Exception: when `--first-match` is supplied, the command SHALL select the first match with a stderr warning; the steps of a daemon `exec.runScript` request select it without writing that warning (#220).

The policy applies to every resolution. A step of one daemon `exec.runScript` request that reuses the position resolved earlier in that request, after a check that the position still shows a URL the matcher accepts, makes no resolution and so does not count matches again (Requirement: Shared target resolution in `script-exec`); the first resolution of the run, and every resolution after a failed check, applies the policy in full.

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

#### Scenario: the first resolution of an exec run applies the policy

- **WHEN** Safari has two tabs matching `--url plaud` and a daemon exec run with `--url plaud` reaches its first step that needs the target
- **THEN** that resolution SHALL fail with `ambiguousWindowMatch`
- **AND** no step SHALL dispatch against either tab
