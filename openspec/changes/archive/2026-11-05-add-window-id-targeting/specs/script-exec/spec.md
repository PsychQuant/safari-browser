## MODIFIED Requirements

### Requirement: Shared target resolution

The `exec` command SHALL accept the standard TargetOptions flags. Ten of them are *target flags*, a closed list: `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--window-id`, `--tab-in-window`, `--document`, `--tab` and `--profile`. `--first-match` and `--mark-tab` are not target flags and do not replace the exec-level target. When a step's `args` include any target flag (`--profile` included, e.g., `["--window", "2"]`), that step SHALL resolve using only its own target flags, which replace the exec-level ones for that step on both paths, and that resolution SHALL NOT replace the exec-level one. The replacement is whole: an exec-level `--profile` does not restrict a step that names a target flag of its own. A step that carries `--first-match` and no target flag keeps the exec-level target and is not run in-process (see Requirement: Daemon-routed execution when available), so its own `--first-match` is honoured. A multi-match `--url` at `exec` level SHALL fail closed on an ambiguous match unless `--first-match` is supplied, as the ambiguous-window-match rules say for other commands (the warning those rules write to stderr is not written on the daemon path, #220); ambiguity and `--first-match` SHALL be decided at each resolution of the exec-level target.

On the daemon path, the exec-level target SHALL be resolved when the first dispatched step needs it, not before the run (the tab-ownership marker, `--mark-tab`, is the one exception: it reads and rewrites the target's title before the first step and, in ephemeral mode, again when the run ends, and it resolves the target within `--profile` like everything else): a step skipped by `if:`, a `documents` step, and a step whose command cannot run in-process SHALL NOT trigger a resolution, and a step whose command cannot run in-process SHALL fail before any resolution. A successful resolution SHALL be reused by a later step only if the exec-level target is a URL pattern (`--url`, `--url-exact`, `--url-endswith`, or `--url-regex`, with or without `--profile`), and a check made immediately before that step, in one AppleScript, confirms that the resolved window and tab position still shows a URL the pattern accepts; that condition does not oblige reuse: a resolution that carries no window identity (an enumeration without window ids) is never reused and every step resolves afresh. This is a closed list; no other target form SHALL be reused on the grounds that it resembles one. The check establishes that the position currently shows a matching URL, not that it is still the tab that was first resolved (see Requirement: Daemon-routed execution when available). Every other exec-level target form — `--document N`, `--tab N`, `--window N`, `--window N --tab-in-window M`, `--window-id W`, `--window-id W --tab-in-window M`, `--profile` alone, and no target flag — SHALL be resolved afresh for every step. If the check fails or raises any error while the request is not cancelled, the system SHALL discard the resolution and resolve afresh; when the request is cancelled, whatever error the check raised, the system SHALL propagate the cancellation without resolving. A failed resolution SHALL leave nothing to reuse.

A cancelled request SHALL start no further step. The daemon cancels an in-flight request when it shuts down or its listener fails; it does not yet cancel one whose client has disconnected (#242). The interpreter SHALL check for cancellation before each step, on both paths. A step run in-process SHALL check before it starts and again after its target was resolved and before its command runs, whichever way it names its target (the shared one, target flags of its own, or a `documents` step that resolves nothing), so that a resolver which finishes after the cancellation is not followed by the command; the tab-ownership marker SHALL check before it wraps the title. A child process of the subprocess path that has already been started is not interrupted. A cancellation raised by a step SHALL end the run and SHALL NOT be recorded as a step error, and `onError: continue` SHALL NOT continue past it. A command that is already running is not interrupted by this requirement.

Reuse is confined to one `exec.runScript` request: nothing resolved SHALL be carried across requests, and every reuse within a request is checked first. This is the scope in which the persistent-daemon rule against caching Safari state applies to exec. The reused resolution is held by the exec dispatcher, the caller of the resolver; the resolver itself keeps no state between calls, as the document-targeting requirement says.

The subprocess path resolves the exec-level target inside every step's own command and reuses nothing.

#### Scenario: shared resolution across steps

- **WHEN** `safari-browser exec --url plaud --script steps.json` runs a 3-step script on the daemon path
- **AND** none of the steps include per-step target flags
- **AND** the resolved tab keeps showing a URL that contains `plaud`
- **THEN** target resolution SHALL run exactly once, at the first step
- **AND** steps 2 and 3 SHALL each be preceded by one check of the resolved tab
- **AND** all 3 steps SHALL dispatch against the same resolved window + tab pair

#### Scenario: per-step override

- **WHEN** the exec-level target is `--url plaud` but step 2's `args` include `["--window", "2"]`
- **THEN** step 2 SHALL resolve window 2 and dispatch against that target
- **AND** the first step that needs the exec-level target SHALL resolve it, and each later step that uses it SHALL be subject to the check before reuse

#### Scenario: resolved position no longer matches

- **WHEN** a daemon exec run has resolved `--url plaud` and, before the next step, the resolved position stops showing a URL that contains `plaud`: the tab navigates away, the tab closes and nothing that matches takes its place, or its window closes
- **THEN** the next step SHALL resolve `--url plaud` afresh
- **AND** SHALL report the not-found error of that resolution, or dispatch against the tab it finds

#### Scenario: a tab that takes over a matching position is not detected

- **WHEN** a daemon exec run has resolved `--url plaud` to the tab at one position, that tab closes, and the tab that moves into the position shows a URL that contains `plaud`
- **THEN** the check SHALL pass and the next step SHALL dispatch against the tab now at the position, without a further enumeration
- **AND** closing or moving a tab is not itself detected: only the URL shown at the position is checked

#### Scenario: check fails with an unrecognised error

- **WHEN** the check before reuse raises an AppleScript error whose message carries no numeric code
- **THEN** the system SHALL treat the check as failed and resolve afresh rather than fail the step

#### Scenario: a failed resolution is not reused

- **WHEN** a daemon exec run resolved `--url target` to one tab, a later step found no matching tab, and before the step after that the tab matches again while a second tab also matches
- **THEN** that step SHALL resolve afresh and report the ambiguous match
- **AND** SHALL NOT dispatch against the tab resolved before the failure

#### Scenario: a cancelled request runs nothing more

- **WHEN** a daemon exec run of five steps, every one with `onError: continue`, is cancelled while its first step is resolving the exec-level target, and the steps after it are a `documents` step, a step with a `--url` of its own, a step with a `--document` of its own, and a step that uses the exec-level target
- **THEN** the run SHALL end by propagating the cancellation, not with a result array in which a step failed
- **AND** no step after the cancellation SHALL resolve a target or issue its command
- **AND** a step whose own target was resolved by a resolver that finished after the cancellation SHALL NOT issue its command

#### Scenario: a skipped or non-resolving step triggers no resolution

- **WHEN** a daemon exec run has `--url plaud`, one step is skipped by `if:`, and another is a `documents` step
- **THEN** neither step SHALL resolve the exec-level target, whether or not `plaud` is shown by any tab

#### Scenario: `--first-match` is decided at each resolution

- **WHEN** a daemon exec run has `--url plaud --first-match`, several tabs match, and 3 steps dispatch while the resolved tab keeps matching
- **THEN** the first match in window and tab order SHALL be resolved once, at the first step
- **AND** steps 2 and 3 SHALL reuse it after the check

#### Scenario: position-based targets resolve every step

- **WHEN** a daemon exec run's exec-level target is `--document 2`, `--window 1`, or `--profile Work` alone, and 3 steps dispatch
- **THEN** the target SHALL be resolved for each of the 3 steps
- **AND** no check before reuse SHALL be made
