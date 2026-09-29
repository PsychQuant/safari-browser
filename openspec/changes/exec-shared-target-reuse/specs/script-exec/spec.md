## MODIFIED Requirements

### Requirement: Shared target resolution

The `exec` command SHALL accept `--url`, `--window`, `--document`, and `--tab` flags via the standard TargetOptions group. When provided, the resolved `ResolvedWindowTarget` SHALL be computed once before any step runs and passed to every step's dispatch. When a step's `args` include target flags (e.g., `["--window", "2"]`), that step SHALL re-resolve using the overriding flags. Multi-match `--url` at `exec` level SHALL behave identically to other commands per the ambiguous-window-match rules (fail-closed unless `--first-match` supplied); ambiguity and `--first-match` SHALL be decided at that resolution. On the daemon path, before a step reuses a `--url` shared target, the system SHALL check in one AppleScript that the resolved tab still shows a URL the pattern accepts; if the check fails or raises any error other than cancellation, the system SHALL discard the resolution and resolve the shared target afresh. A step whose command cannot run in-process SHALL fail before any target resolution. Nothing resolved SHALL be carried across `exec.runScript` requests.

#### Scenario: shared resolution across steps

- **WHEN** `safari-browser exec --url plaud --script steps.json` runs a 3-step script
- **AND** none of the steps include per-step target flags
- **THEN** target resolution SHALL run exactly once at `exec` start
- **AND** all 3 steps SHALL dispatch against the same resolved window + tab pair

#### Scenario: per-step override

- **WHEN** the exec-level target is `--url plaud` but step 2's `args` include `["--window", "2"]`
- **THEN** step 2 SHALL re-resolve for window 2 and dispatch against that target
- **AND** steps 0, 1, and 3+ SHALL continue using the exec-level resolution

#### Scenario: resolved tab no longer matches

- **WHEN** a daemon exec run has resolved `--url plaud` and the tab navigates away, closes, or its window closes before the next step
- **THEN** the next step SHALL resolve `--url plaud` afresh
- **AND** SHALL report the not-found error of that resolution, or dispatch against the tab it finds

#### Scenario: check fails with an unrecognised error

- **WHEN** the check before reuse raises an AppleScript error whose message carries no numeric code
- **THEN** the system SHALL treat the check as failed and resolve afresh rather than fail the step
