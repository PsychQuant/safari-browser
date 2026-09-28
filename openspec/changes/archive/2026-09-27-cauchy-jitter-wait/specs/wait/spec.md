## ADDED Requirements

### Requirement: Wait for a randomized duration
The system SHALL support `safari-browser wait --jitter cauchy`, which draws one duration from a Cauchy distribution doubly truncated to [`--min`, `--max`] milliseconds and then pauses for that duration. Truncation SHALL discard mass outside the interval and renormalize; the system SHALL NOT clamp out-of-range draws to a bound. `--median` SHALL specify the median of the truncated distribution. Defaults SHALL be `--min 2000`, `--max 60000`, `--median 3000`; without `--scale`, the scale SHALL be 0.8 × min(`--median` − `--min`, `--max` − `--median`), which is 800 for the default bounds. `--max` above 3600000 ms SHALL be rejected unless `--allow-long-wait` is given. When the interquartile range of the truncated distribution is below 5% of `--median` or below one nanosecond, the system SHALL print a warning to stderr before waiting and SHALL still wait. `--scale` SHALL NOT exceed 100 × (`--max` − `--min`). `--seed <n>` SHALL fix the single duration drawn by that invocation, so that tests are reproducible within the same supported numerical environment; because each invocation is a separate process, repeating the same seed SHALL yield the same duration. `--max` SHALL be the only cap on a jittered wait; `--timeout` SHALL NOT apply. `--jitter` SHALL NOT be combined with positional milliseconds, `--for-url`, or `--js`.

#### Scenario: Default randomized wait stays within bounds
- **WHEN** user runs `safari-browser wait --jitter cauchy`
- **THEN** the CLI pauses for a duration strictly between 2000ms and 60000ms

#### Scenario: No point mass at the bounds
- **WHEN** 100000 durations are drawn with a fixed seed and default parameters
- **THEN** no drawn duration equals 2000ms or 60000ms, and the empirical median is within 1% of 3000ms

#### Scenario: Seed fixes the draw of one invocation
- **WHEN** user runs `safari-browser wait --jitter cauchy --seed 42` twice with the same parameters
- **THEN** both invocations request the same sleep duration within the same supported numerical environment
- **AND** the system SHALL guarantee reproducibility, not a one-to-one seed-to-duration mapping; collisions between different seeds are permitted

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

#### Scenario: Default scale follows the bounds
- **WHEN** user runs `safari-browser wait --jitter cauchy --min 1000 --max 3000 --median 1500` without `--scale`
- **THEN** the scale is 400 and the median is reachable, so the CLI waits instead of reporting an unreachable median

#### Scenario: Nearly fixed draws are reported
- **WHEN** user runs `safari-browser wait --jitter cauchy --min 1000 --max 3000 --median 1500 --scale 1`
- **THEN** the CLI prints a warning to stderr that the delays are nearly fixed, then waits

#### Scenario: A long upper bound needs an explicit opt-in
- **WHEN** user runs `safari-browser wait --jitter cauchy --max 600000000`
- **THEN** the CLI returns a validation error naming `--allow-long-wait`, before starting a wait
- **AND WHEN** the same command adds `--allow-long-wait`
- **THEN** the parameters are accepted

#### Scenario: Achievable median needs a location outside the truncation interval
- **WHEN** bounds are [0,10] ms, scale is 1 ms, and the requested median is 0.902 ms
- **THEN** the distribution SHALL be accepted and solved on the central monotone branch without restricting its untruncated location to [0,10]

#### Scenario: Sub-nanosecond or single-quantum interval
- **WHEN** the open interval between min and max contains fewer than two integer nanosecond durations
- **THEN** the CLI SHALL reject the request before sleeping rather than produce a fixed zero or single-quantum wait

##### Example: No integer nanosecond is available
- **GIVEN** min=1e-7 ms, max=9e-7 ms, median=5e-7 ms, scale=1e-7 ms
- **WHEN** the command is validated
- **THEN** it returns a validation error without sleeping

#### Scenario: Sleep API quantization
- **WHEN** a valid continuous duration is drawn
- **THEN** the CLI SHALL use the nearest representable integer nanosecond duration strictly inside the bounds represented by the parsed Double parameters, with checked conversion and no endpoint sleep
- **AND** it SHALL preserve the continuous truncated-Cauchy draw before this documented clock quantization

##### Example: Two legal ticks
- **GIVEN** min=1e-7 ms, max=2.9e-6 ms, median=1.5e-6 ms, scale=4e-7 ms
- **WHEN** the command passes a sampled duration to the sleep API
- **THEN** the argument is either 1 ns or 2 ns

#### Scenario: Numerical sampling failure
- **WHEN** bounded numerical resampling cannot produce a finite interior sample
- **THEN** the operation SHALL fail explicitly rather than substitute a fixed median

##### Example: Exhausted numerical resampling
- **GIVEN** an injected generator that always returns zero bits
- **WHEN** the sampler exhausts 64 attempts to obtain an interior uniform value
- **THEN** it throws numericalExhaustion and returns no duration

#### Scenario: Nanosecond quantization concentration is reported
- **WHEN** min=0 ms, max=3e-6 ms, median=1e-6 ms and scale=1e-7 ms
- **THEN** the CLI SHALL print a nearly fixed warning to stderr that names nanosecond resolution, even though the continuous IQR exceeds 5% of the median
- **AND** it SHALL still request a legal interior integer nanosecond sleep
