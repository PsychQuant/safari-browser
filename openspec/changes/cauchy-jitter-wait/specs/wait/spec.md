## ADDED Requirements

### Requirement: Wait for a randomized duration
The system SHALL support `safari-browser wait --jitter cauchy`, which draws one duration from a Cauchy distribution doubly truncated to [`--min`, `--max`] milliseconds and then pauses for that duration. Truncation SHALL discard mass outside the interval and renormalize; the system SHALL NOT clamp out-of-range draws to a bound. `--median` SHALL specify the median of the truncated distribution. Defaults SHALL be `--min 2000`, `--max 60000`, `--median 3000`, `--scale 800`. `--seed <n>` SHALL make the drawn sequence reproducible. `--jitter` SHALL NOT be combined with positional milliseconds, `--for-url`, or `--js`.

#### Scenario: Default randomized wait stays within bounds
- **WHEN** user runs `safari-browser wait --jitter cauchy`
- **THEN** the CLI pauses for a duration strictly between 2000ms and 60000ms

#### Scenario: No point mass at the bounds
- **WHEN** 100000 durations are drawn with a fixed seed and default parameters
- **THEN** no drawn duration equals 2000ms or 60000ms, and the empirical median is within 1% of 3000ms

#### Scenario: Seed reproduces the sequence
- **WHEN** two samplers are created with the same `--seed` value and parameters
- **THEN** they produce identical sequences of durations

#### Scenario: Unreachable median is rejected
- **WHEN** user runs `safari-browser wait --jitter cauchy --scale 5000 --median 3000`
- **THEN** the CLI returns a validation error that states the achievable median range for that scale, before starting a wait

#### Scenario: Conflicting wait modes are rejected
- **WHEN** user runs `safari-browser wait 2000 --jitter cauchy` or combines `--jitter` with `--for-url` or `--js`
- **THEN** the CLI returns a validation error before starting a wait

#### Scenario: Invalid parameters are rejected
- **WHEN** `--min` is negative, `--min` is not less than `--median`, `--median` is not less than `--max`, `--scale` is not positive, or `--max` exceeds the representable nanosecond range
- **THEN** the CLI returns a validation error before starting a wait
