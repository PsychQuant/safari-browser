## Context

Multi-agent automation environments are an emerging reality on `safari-browser` users' machines: Claude Code orchestrating multiple parallel agents, plus user-driven workflows, plus background processes. None of these have a way to discover that a Safari tab is *currently being driven*. Without that signal, two agents can race on the same tab, destructive operations can hit in-flight workflows, and "tab busy" warnings are impossible to surface.

Issue #39 (Follow-up D from the #32 audit) flagged this as a Wave-1 gap. The `/spectra-discuss` session for #39 (2026-04-25) walked through the design space and produced 5 binding decisions which this design captures.

**Stakeholders:**
- LLM agents performing automation (the only realistic readers of `tab is-marked`)
- Multi-process orchestrators (CI pipelines, parallel test runners)
- The user — passively, via the spec's commitment that default behavior never mutates titles

**Constraints:**
- Must not violate `non-interference` default contract
- Must not leak agent identity to AX / Spotlight / Stage Manager / screen recording
- Must preserve `stateless-CLI` contract for the default path
- Must compose with `persistent-daemon` (#37) without per-AppleScript-call marker churn

## Goals / Non-Goals

**Goals:**
- One canonical machine-readable ownership probe (`tab is-marked`)
- Opt-in marker that vanishes after the operation by default (no persistent state pollution)
- Hard-coded marker content so the system cannot be repurposed as an identity side-channel
- Best-effort restore that never fights JS-driven title changes

**Non-Goals:**
- User-visible indicator (the original "tell the user this tab is being driven" framing — dropped because zero-width is invisible and emoji collides with the security review)
- Caller-supplied marker content
- Cross-machine ownership coordination
- Always-on marker (no opt-in)
- External state files for ownership tracking
- Force-restore on title race

## Decisions

### Zero-width marker

The marker is `U+200B` (zero-width space) bracketing the title — `\u{200B}<original-title>\u{200B}`. The choice eliminates the side-channel concern raised in the #32 security review:

- AX (`AXTitle`) returns the title literally; zero-width characters are present in the string but invisible to the user
- Spotlight tab indexing reads the same string; zero-width is preserved but contributes nothing searchable
- Stage Manager / Mission Control thumbnails render the visible glyphs only; marker is invisible
- Screen recording captures pixels; zero-width is invisible

**Alternatives considered:**
- **Emoji prefix (🟢 / 🤖 / etc.)** — rejected. Visible to AX, Spotlight, Stage Manager, screen recording. Original #32 review flagged this as a cross-process side-channel.
- **Custom Unicode glyph (e.g., U+2063 invisible separator, U+FEFF zero-width no-break space)** — equivalent to U+200B in practice; chose ZWSP for its broader implementation maturity in font/text engines.
- **Bracketed string in title (`[sb-marked]`)** — rejected. Visible, large; pollutes browser history and bookmark titles.

**Rationale**: zero-width gives us a queryable signal with zero human-visible footprint. The trade-off is that the original "tell the user" goal collapses — see Non-Goals.

### Opt-in via `--mark-tab` flag

Three opt-in signals (mirroring daemon's pattern from #37):
1. Per-command `--mark-tab` flag
2. Session-wide `SAFARI_BROWSER_MARK_TAB=1` env
3. Direct invocation of `tab is-marked` / `tab unmark` (these don't need opt-in because they're explicit-purpose subcommands)

The default OFF rule is the non-interference contract surface. **Every existing subcommand's behavior is unchanged when `--mark-tab` is absent.** This is a hard guarantee, testable via byte-identical title comparison before/after.

**Alternatives considered:**
- **Always-on, no flag** — rejected. Categorical non-interference violation; would break workflows that depend on title stability.
- **Auto-on when daemon is active** — rejected. Daemon opt-in does not imply ownership-marker opt-in. They are orthogonal.

### Ephemeral marker default

Ephemeral mode (default) wraps before the operation, unwraps after. Persist mode leaves the marker until `tab unmark` or tab close.

- **Ephemeral** is the right default because it preserves stateless-CLI semantics: nothing carries across invocations.
- **Persist** is necessary for multi-invocation workflows where the agent runs `safari-browser click ...` followed by `safari-browser fill ...` and wants both to publish "I'm working here" to siblings without re-issuing the marker per call.

**Alternatives considered:**
- **Persist-only** — rejected. Cleanup burden falls entirely on the agent; crashed agents leave permanent markers. Not safe by default.
- **Time-based expiry** — rejected. Adds a daemon dependency for the timer and a "marker stale" race. Persistence binary (until-unmark vs ephemeral) is simpler.

### Best-effort title-restore

If the title changed during the operation (page navigated, JS rewrote `document.title`, Safari rebranded), cleanup compares expected-title vs current-title and on divergence emits one stderr line and exits. No retry, no force-set.

Forcing the original title back would be Layer-3 actively-interfering and could enter an oscillation loop if the page's JS keeps rewriting. Best-effort + warning preserves the user's actual page state and surfaces the race for the agent to handle.

**Alternatives considered:**
- **Force-restore with retry budget** — rejected. Oscillation risk; requires defining retry limits that have no good default.
- **Silent failure** — rejected. Agent has no way to know cleanup happened or didn't; observability matters for ownership semantics.

### Daemon-spanning marker

When a request arrives at the daemon with `markTab: true`, the daemon's request actor wraps the title once at the start of the request and unwraps once at the end (or on the actor's error path). The marker spans **the whole request lifetime**, including any chunked-read sequence (`doJavaScriptLarge`) the request internally triggers.

If the marker were applied per AppleScript call instead, a 5-step `exec` script under `--mark-tab` would wrap-unwrap-wrap-unwrap... 10 times — meaningless churn that would also widen the title-race window.

**Alternatives considered:**
- **Per-AppleScript-call marker** — rejected for the churn reason above.
- **Marker only at exec-script boundary, not per individual command** — equivalent in effect to "request-scoped" because the daemon's request actor is already serial.

## Risks / Trade-offs

- **[Risk] Agents over-rely on `is-marked` for hard exclusion** → Mitigation: spec is clear that the marker is a *probe*, not a *lock*. Two agents can both wrap before either checks; the marker is advisory. Document this in CLAUDE.md.
- **[Risk] Zero-width in titles confuses users when copy-pasting** → Mitigation: ephemeral mode is the default; persist mode is opt-in and the agent owns the cleanup contract. Users who copy a title with U+200B see no visible difference; the character is stripped by most paste targets.
- **[Risk] Future contributor adds `--mark-tab "<custom>"`** → Mitigation: spec hard-codes the marker constant in `Requirement: Marker content is hardcoded`; future change must amend the spec, not just the code.
- **[Risk] `tab is-marked` is racy — title can change between query and use** → Accept. The probe is best-effort. Documented as advisory.
- **[Trade-off] Goal #1 ("tell the user") is dropped** → Recorded explicitly in Non-Goals. The remaining value (machine-readable probe) is the part that survives the principle stack.

## Migration Plan

1. No migration needed. Default behavior is unchanged (no title mutation).
2. New flag and subcommands are purely additive.
3. Existing users see zero impact unless they explicitly opt in.
4. No rollback concern — feature can be removed entirely without affecting any existing code path.

## Open Questions

- **Should `safari-browser tab list` show a "marked" column?** Probably yes, follow-up tweak to that subcommand. Not in this change's scope.
- **Should daemon emit a `marker.wrap` / `marker.unwrap` event in its log?** Spec says yes (Requirement: Non-interference classification scenario 2). Verify the daemon's existing log format accommodates this without scope creep into daemon's own spec.
- **Multi-tab marker semantics?** Current spec is single-tab-per-invocation. If someone wraps `--first-match` against a multi-match URL, only the chosen tab gets marked. Document this clearly in CLAUDE.md.
