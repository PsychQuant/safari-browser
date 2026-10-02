## MODIFIED Requirements

### Requirement: Daemon mode behavioural parity with stateless mode

All target-resolution behaviour defined in this capability — including spatial gradient layer selection, fail-closed handling of `ambiguousWindowMatch`, cross-Space detection, and tab-bar ground truth — SHALL produce identical outcomes in daemon mode and stateless mode given identical Safari state at request time. Daemon mode MUST NOT use cached window lists, tab lists, or URL mappings to shortcut the layer decision.

One case is not covered by that sentence. Within a single `exec.runScript` request, after the exec-level URL target has been resolved, a later step reuses the resolved window-and-tab position after a check, made immediately before that step, that the position still shows a URL the matcher accepts (Requirement: Shared target resolution in `script-exec`). That reuse is held by the request's own dispatcher and ends with the request: it is not a cache that outlives a request, and every resolution (the first of the run, and every one after a failed check) applies the rules above in full, including `ambiguousWindowMatch`. Because the check looks at the position and not at the tab, a second tab that starts to match during the run does not raise `ambiguousWindowMatch` for a step that reuses the position; the stateless path, which resolves in every step, reports it.

#### Scenario: Ambiguous --url fails closed in both modes

- **GIVEN** two Safari windows whose URLs both match `--url plaud`
- **WHEN** the user runs `safari-browser click @e5 --url plaud` once without `--daemon` and once with `--daemon`
- **THEN** both invocations produce the same `ambiguousWindowMatch` error listing the same set of matches

#### Scenario: Cross-Space resolution matches between modes

- **GIVEN** a Safari window on a different macOS Space whose URL matches `--url plaud`
- **WHEN** the user runs `safari-browser snapshot --url plaud` once without `--daemon` and once with `--daemon`
- **THEN** both invocations apply the same Layer 4 behaviour (do not raise across Spaces; open a new tab in the current Space) or both apply the same Layer 3 behaviour if AX permission permits, consistently with the stateless path

#### Scenario: Tab reordered between requests is observed

- **GIVEN** daemon mode is enabled and a request has just completed
- **WHEN** the user manually drags a tab in Safari before the next request
- **THEN** the next daemon-routed request observes the new tab order — identical to what the stateless path would observe

#### Scenario: A resolution reused within one exec request does not outlive it

- **GIVEN** a daemon `exec.runScript` request that resolved `--url plaud` at its first step and reused the position for its second
- **WHEN** a second request with the same script starts
- **THEN** the second request resolves `--url plaud` afresh at its first step and applies `ambiguousWindowMatch` to that resolution
