## ADDED Requirements

### Requirement: Wait for a randomized duration
The system SHALL support `safari-browser wait --jitter cauchy`, which draws one duration from a Cauchy distribution doubly truncated to [`--min`, `--max`] milliseconds and then pauses for that duration. Truncation SHALL discard mass outside the interval and renormalize; the system SHALL NOT clamp out-of-range draws to a bound. `--median` SHALL specify the median of the truncated distribution. Defaults SHALL be `--min 2000`, `--max 60000`, `--median 3000`, `--scale 800`. `--scale` SHALL NOT exceed 100 × (`--max` − `--min`). `--seed <n>` SHALL fix the single duration drawn by that invocation, so that tests are reproducible; because each invocation is a separate process, repeating the same seed SHALL yield the same duration. `--max` SHALL be the only cap on a jittered wait; `--timeout` SHALL NOT apply. `--jitter` SHALL NOT be combined with positional milliseconds, `--for-url`, or `--js`.

#### Scenario: Default randomized wait stays within bounds
- **WHEN** user runs `safari-browser wait --jitter cauchy`
- **THEN** the CLI pauses for a duration strictly between 2000ms and 60000ms

#### Scenario: No point mass at the bounds
- **WHEN** 100000 durations are drawn with a fixed seed and default parameters
- **THEN** no drawn duration equals 2000ms or 60000ms, and the empirical median is within 1% of 3000ms

#### Scenario: Seed fixes the draw of one invocation
- **WHEN** user runs `safari-browser wait --jitter cauchy --seed 42` twice with the same parameters
- **THEN** both invocations pause for the same duration, and a different seed yields a different duration

#### Scenario: Oversized scale is rejected
- **WHEN** user runs `safari-browser wait --jitter cauchy --scale 1e13`
- **THEN** the CLI returns a validation error stating the maximum scale for the interval, before starting a wait, and does not terminate by signal

#### Scenario: Unreachable median is rejected
- **WHEN** user runs `safari-browser wait --jitter cauchy --scale 5000 --median 3000`
- **THEN** the CLI returns a validation error that states the achievable median range for that scale, before starting a wait

#### Scenario: Conflicting wait modes are rejected
- **WHEN** user runs `safari-browser wait 2000 --jitter cauchy` or combines `--jitter` with `--for-url` or `--js`
- **THEN** the CLI returns a validation error before starting a wait

#### Scenario: Invalid parameters are rejected
- **WHEN** `--min` is negative, `--min` is not less than `--median`, `--median` is not less than `--max`, `--scale` is not positive, or `--max` exceeds the representable nanosecond range
- **THEN** the CLI returns a validation error before starting a wait
