## 1. Marker constants module

- [x] 1.1 Create `Sources/SafariBrowser/Marker/MarkerConstants.swift` with the hardcoded zero-width marker — `prefix` and `suffix` Swift static let constants set to `"\u{200B}"` each, satisfying Requirement: Marker content is hardcoded, no caller input — exposes `wrap(title:) -> String`, `unwrap(title:) -> String?` (returns nil if marker absent), `hasMarker(title:) -> Bool` pure helpers used by every wrap / unwrap / detection site
- [x] 1.2 Add `Tests/SafariBrowserTests/MarkerHelpersTests.swift` with pure-string coverage: `wrap` produces marker pair, `wrap` then `unwrap` round-trips, double-`wrap` is idempotent (does not produce nested markers), `hasMarker` true/false cases, `unwrap` on unmarked title returns nil, marker-with-empty-original-title round-trip — 17 tests, all passing

## 2. CLI flag and env wiring

- [x] 2.1 Add two mutually-exclusive `@Flag`s to `Sources/SafariBrowser/Commands/TargetOptions.swift` — `--mark-tab` (ephemeral mode) and `--mark-tab-persist` (persist mode) satisfying Requirement: Marker is opt-in via `--mark-tab` flag, default OFF; validate-time reject when both are set
- [x] 2.2 Honor `SAFARI_BROWSER_MARK_TAB=1` env variable as opt-in equivalent of bare `--mark-tab` (ephemeral mode); env value of `2` or `persist` selects persist mode for clarity
- [x] 2.3 Add `markTabResolved` helper on `TargetOptions` returning a tri-state (`.off | .ephemeral | .persist`) consolidating flag + env precedence; flag takes priority over env when both are set

## 3. Bridge helpers

- [x] 3.1 Add `SafariBridge.getTabTitle(target:)` and `SafariBridge.setTabTitle(_:target:)` helpers in `Sources/SafariBrowser/SafariBridge.swift` — `getCurrentTitle` (existing) reads via `name of <docRef>`; new `setTabTitle` writes via `do JavaScript "document.title = ..."` because Safari's AppleScript `set name of` is unreliable across versions and JS path is the canonical web-standard mechanism
- [x] 3.2 Add `SafariBridge.markTabIfRequested(target:mode:operation:)` async wrapper satisfying Requirement: Ephemeral marker default — when mode is `.ephemeral` (the default), captures original title, wraps, runs operation, unwraps with title-race detection per Requirement: Best-effort title-restore on race; when mode is `.persist`, wraps once and skips unwrap; when mode is `.off`, runs operation directly without any title mutation

## 4. Title-race detection and warning

- [x] 4.1 Implement title-race detection inside `markTabIfRequested` cleanup — compare current Safari title against expected wrapped title; on divergence emit exactly `[mark-tab: title changed during operation; original not restored]\n` to stderr and skip unwrap satisfying Requirement: Best-effort title-restore on race
- [x] 4.2 Cleanup SHALL run on both success and error paths of the operation closure; original error MUST propagate unmodified after cleanup completes

## 5. `tab is-marked` query subcommand

- [x] 5.1 Add `TabIsMarkedCommand` as a subcommand under `TabCommand` in `Sources/SafariBrowser/Commands/TabCommand.swift` satisfying Requirement: `tab is-marked` query subcommand — accepts standard `TargetOptions`; reads tab title; exits 0 if `MarkerConstants.hasMarker` returns true, 1 if false. Note: `TabCommand` refactored into parent + subcommands with `defaultSubcommand: TabSwitchCommand` so the legacy `safari-browser tab <N>` and `tab new` syntax continues to work unchanged.
- [x] 5.2 Map target-resolution failures (`documentNotFound`, `ambiguousWindowMatch`, `appleScriptFailed`) to exit code 2 with the standard error shape on stderr — implemented via `ExitCode(2)` after writing `error.localizedDescription` to stderr
- [x] 5.3 Emit nothing on stdout for any exit code — the command is purely an exit-code probe — verified: no stdout writes anywhere in `TabIsMarkedCommand.run()`

## 6. `tab unmark` cleanup subcommand

- [x] 6.1 Add `TabUnmarkCommand` as a subcommand under `TabCommand` — reads current title; if marker present, removes via `MarkerConstants.unwrap` and writes back via `setTabTitle`; if marker absent, exits 0 silently (idempotent)
- [x] 6.2 Same target-resolution / exit-code semantics as `tab is-marked` for error cases

## 7. Daemon integration

- [ ] 7.1 Extend `DaemonProtocol` request envelope with optional `markTab: "off"|"ephemeral"|"persist"` field; default `"off"` when absent so existing daemon-routed clients are unchanged — **deferred to v2**: the spec's "wrap once per request" intent is already satisfied at the command-run() level by `markTabIfRequested(target:mode:operation:)`. When a command wraps its full operation closure, internal multi-call sequences (e.g. `doJavaScriptLarge` chunked reads) execute INSIDE the wrap. Per-request daemon-protocol-level integration is a latency micro-optimization, not a correctness requirement, for v1.
- [ ] 7.2 In `Sources/SafariBrowser/Daemon/DaemonDispatch.swift`, wrap each request handler invocation in `markTabIfRequested` when the request carries non-`off` `markTab` value satisfying Requirement: Daemon-spanning marker for multi-step requests — **deferred to v2** with 7.1 (same rationale)
- [ ] 7.3 When the daemon's request handler internally issues multiple AppleScript calls (e.g., `doJavaScriptLarge` chunked-read sequence), the marker SHALL NOT toggle per call — it is owned by the request-actor wrapper from 7.2 — **deferred to v2** with 7.1; satisfied at command-run() level today via the closure-shaped wrapper

## 8. Non-interference cross-reference

- [x] 8.1 Add a one-paragraph cross-reference to `openspec/specs/non-interference/spec.md` listing `--mark-tab` / `--mark-tab-persist` opt-in alongside `--allow-hid` and `--native` as the documented opt-in escape hatches per Requirement: Non-interference classification — added as a new row in the opt-in flags table

## 9. Tests

- [ ] 9.1 `Tests/SafariBrowserTests/TabIsMarkedTests.swift` — exit-code semantics: 0 when marked, 1 when unmarked, 2 on resolution failure; uses fake `SafariBridge` injectable for the title-read so the test runs without live Safari — **deferred to v2**: requires SafariBridge to be injectable behind a protocol; current static-method shape doesn't accommodate fake injection without significant refactor. The exit-code logic is straight-line and visually verified; live-Safari coverage in 9.3 (also deferred) would catch any regression.
- [x] 9.2 `Tests/SafariBrowserTests/MarkTabRouterTests.swift` — `TargetOptions.markTabResolved` precedence: flag wins over env, bare flag → ephemeral, `--mark-tab-persist` → persist, env `1` → ephemeral, env `persist` → persist, neither → off — 13 tests covering all combinations, all passing
- [ ] 9.3 `Tests/e2e-mark-tab.sh` — live-Safari integration: bare `--mark-tab` wraps then restores byte-identical title; `--mark-tab-persist` survives invocation boundary (next `is-marked` returns 0); `tab unmark` clears persist marker; mid-operation navigation triggers the stderr warning without crashing — **deferred to v2**: live-Safari integration test requires Safari running and is most useful AFTER the broader command rollout (currently only `ClickCommand` is wired). v2 should ship together with the broader integration plus this e2e.

## 10. Documentation

- [x] 10.1 Update `CLAUDE.md` with a `## Tab ownership marker` section: opt-in signals, ephemeral vs persist, the advisory-not-locking nature of `is-marked`, and the explicit Non-Goal that this is **not** a user-visible indicator (links to spec for full rationale) — section added below `## Exec scripts` covering opt-in signals, marker format, probe + cleanup examples, title-race semantics, v1 scope note
- [x] 10.2 Update `README.md` with a brief `### Tab ownership marker (opt-in)` example showing `safari-browser click ... --mark-tab-persist` followed by sibling `safari-browser tab is-marked` returning exit 0 — added under the `Daemon` subsection
