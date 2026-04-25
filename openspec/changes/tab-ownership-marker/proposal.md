## Why

Multi-agent and multi-process automation environments need a way for one `safari-browser` invocation to **detect** that a Safari tab is currently being driven by another agent — to avoid two agents racing on the same tab, to avoid disrupting an in-flight workflow, or to surface "tab busy" warnings before issuing a destructive op (`close`, `reload`, `open --replace-tab`).

Today there is no such signal. An agent that starts a 30-step `exec` script against `--url plaud` has no way to publish "I'm working here" to a sibling agent on the same machine, and the sibling has no way to read it. Issue #39 (Follow-up D from the #32 audit) flags this as the last open Wave-1 gap.

A naive implementation — emoji prefix in the tab title saying `🟢 [claude]` — collides hard with three project principles (non-interference, spatial-gradient, stateless-CLI) and adds a cross-process side-channel that leaks agent identity to AX / Spotlight / Stage Manager / screen recording. The `/spectra-discuss` session for #39 (2026-04-25) walked through the principle constraints and resolved that the design *must* be opt-in, invisible, content-locked, and ephemeral.

This change formalizes that resolution.

## What Changes

- Add `--mark-tab` flag (and `SAFARI_BROWSER_MARK_TAB=1` env) that opts a single command into wrapping the target tab's title with a fixed zero-width Unicode marker for the duration of the operation
- Add `safari-browser tab is-marked` query subcommand that returns true/false (exit code 0 / 1) when the target tab's title currently contains the marker — the **only** machine-readable ownership probe
- Add `safari-browser tab unmark` for explicit cleanup when a previous `--mark-tab persist` invocation crashed before its restore step ran (gives users an escape hatch from "stuck" markers)
- Marker format is **hardcoded**: a single zero-width-space pair (`U+200B` ... `U+200B`) bracketing the existing title. No caller-supplied content. No agent identity. No emoji.
- Default behavior is **ephemeral**: marker added before the operation, removed after. Optional `--mark-tab persist` mode leaves the marker until explicit `tab unmark` or tab close (for use cases where multiple commands need to share ownership across invocations)
- Title-restore is **best-effort**: if the page navigates or JS rewrites `document.title` during the operation, cleanup logs a single `[mark-tab: title changed during operation; original not restored]` warning to stderr and exits — does not aggressively force-set
- Spec also encodes the **content whitelist** at the requirement level so future extensions (e.g., a `--mark-tab "<custom>"` API) require a spec change, not just a code change

## Non-Goals

- **User-visible indicator** — rejected. The original #32 issue framed marker as "tell the user this tab is being driven by an agent". Zero-width characters are invisible to humans; emoji-based markers leak identity via AX / Spotlight / screen recording. Visibility goal is dropped; the remaining (and still-valuable) use case is **machine-readable ownership probing**. Accept this scope reduction explicitly.
- **Caller-supplied marker content** (e.g., `--mark-tab "[claude]"`) — rejected. Even a friendly caller turns the system into a side-channel for arbitrary identity leakage. Spec hard-codes the marker; future extension requires a spec amendment.
- **Cross-process / cross-machine ownership coordination** — rejected. The marker says "this tab is being driven *somehow*", not "by *whom*". Coordination protocols (e.g., agent-A queries marker, agent-B responds with PID and yields) are out of scope; build them as a separate capability if needed.
- **Always-on marker** (no opt-in flag) — rejected. Mutating tab title on every command would be a categorical non-interference violation and would break workflows that depend on title stability (e.g., title-based polling, browser history search).
- **External state files** for ownership tracking (`/tmp/safari-browser-tabs.json` style) — rejected. Stateless-CLI contract; daemon (#37) is the only sanctioned long-lived state and ownership is too fine-grained for it.
- **Force-restore on title race** — rejected. If JS rewrote the title mid-operation, fighting it would be Layer-3 actively-interfering and could produce oscillation. Best-effort + warning is the right semantic.

## Capabilities

### New Capabilities

- `tab-ownership-marker`: opt-in, content-locked, ephemeral-by-default zero-width marker on Safari tab titles; companion query (`tab is-marked`) and cleanup (`tab unmark`) subcommands

### Modified Capabilities

_(none)_

## Impact

**Affected specs:**
- New `openspec/specs/tab-ownership-marker/spec.md` (full capability)
- Cross-reference in `openspec/specs/non-interference/spec.md` — marker mutation listed as **passively interfering when opted-in, non-interfering when default**

**Affected code:**
- `Sources/SafariBrowser/Commands/TabCommand.swift` — extend with `is-marked` and `unmark` subcommands
- `Sources/SafariBrowser/Commands/TargetOptions.swift` — add `--mark-tab` flag (with `ephemeral|persist` modes; default `ephemeral`)
- `Sources/SafariBrowser/SafariBridge.swift` — add `getTabTitle(target:)` / `setTabTitle(_:target:)` AppleScript helpers; add `wrapWithMarker` / `unwrapMarker` / `hasMarker` pure helpers operating on title strings
- `Sources/SafariBrowser/Marker/MarkerConstants.swift` — new module: hardcoded marker code points (single source of truth, easy to test, hard to misuse)
- Every command that takes `TargetOptions` and accepts `--mark-tab`: wrap operation in `try await markTabIfRequested { ... }` helper at the bridge layer
- `Sources/SafariBrowser/Daemon/DaemonDispatch.swift` — when daemon-routed and the request carries `markTab: true`, daemon owns the wrap/unwrap pair so the marker spans the entire request lifetime even across multiple AppleScript calls

**Affected tests:**
- `Tests/SafariBrowserTests/MarkerHelpersTests.swift` — pure-string tests for `wrapWithMarker` / `unwrapMarker` / `hasMarker`, including idempotence (wrap twice ≠ double-wrap), title-race detection
- `Tests/SafariBrowserTests/TabIsMarkedTests.swift` — `tab is-marked` exit-code semantics (0 when marked, 1 when not, 2 on error)
- `Tests/e2e-mark-tab.sh` — live-Safari integration: `--mark-tab` wraps then restores, `--mark-tab persist` survives invocation boundary, mid-operation navigation triggers stderr warning without crash

**Dependencies:**
- **Soft** — `persistent-daemon` archive (2026-04-25) for the daemon-spanning persist mode; stateless ephemeral mode works without

**Breaking:** none. Purely additive.

**Cross-reference:** `/spectra-discuss tab-ownership-marker` session 2026-04-25 — 5 assumptions captured covering opt-in gate, marker format, persistence default, content whitelist, and best-effort restore semantics. Issue #39 (Follow-up D from #32) is the originating diagnosis.
