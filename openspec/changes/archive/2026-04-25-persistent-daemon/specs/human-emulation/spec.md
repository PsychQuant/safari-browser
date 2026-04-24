## ADDED Requirements

### Requirement: Daemon mode behavioural parity with stateless mode

All target-resolution behaviour defined in this capability — including spatial gradient layer selection, fail-closed handling of `ambiguousWindowMatch`, cross-Space detection, and tab-bar ground truth — SHALL produce identical outcomes in daemon mode and stateless mode given identical Safari state at request time. Daemon mode MUST NOT use cached window lists, tab lists, or URL mappings to shortcut the layer decision.

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
