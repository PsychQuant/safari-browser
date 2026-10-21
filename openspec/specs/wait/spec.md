# wait Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: Wait for duration
The system SHALL pause execution for the specified non-negative number of milliseconds when no URL or JavaScript wait predicate is selected. The millisecond value SHALL be representable as UInt64 nanoseconds; otherwise the CLI SHALL return a validation error before sleeping, without an arithmetic trap. Predicate selection and precedence SHALL remain unchanged.

#### Scenario: Wait 2 seconds
- **WHEN** user runs `safari-browser wait 2000`
- **THEN** the CLI blocks for approximately 2000ms before exiting

#### Scenario: Conversion upper bound
- **WHEN** the pure conversion receives 18_446_744_073_709 milliseconds
- **THEN** it returns 18_446_744_073_709_000_000 nanoseconds without starting a wait

#### Scenario: Overflow rejected
- **WHEN** user runs `safari-browser wait 18446744073710`
- **THEN** the CLI returns a validation error naming the upper bound before starting a wait, rather than terminating by signal

#### Scenario: Negative duration
- **WHEN** the pure conversion receives -1 or Int.min
- **THEN** it returns the existing non-negative-value validation error before converting to UInt64

---
### Requirement: Wait for URL pattern

The system SHALL poll the URL of the target tab every 500 ms until it matches the given pattern, then exit. The `--for-url` flag accepts the pattern. (The previous `--url` flag was repurposed as a global targeting flag in #23 — see the `document-targeting` capability.)

The target SHALL be resolved once, before the first poll. Resolution time counts against `--timeout`, and the first poll SHALL always run, even when resolution used up the timeout. `--timeout` bounds when a poll after the first may start, and after an unsatisfied poll the wait SHALL ask to sleep no longer than until the deadline. It does not bound how long the command takes: resolving the target and a poll that has started are not cut short by `--timeout`, so the command can end later than it. The calls a poll makes, their own limits and what happens when one fails are not changed by this requirement and are not stated here. The command's help SHALL say that the command can end later than `--timeout`. Which tab is read is decided by the target form, a closed list:

1. The default target and `--window N` SHALL read the window's current tab at command start. Each poll SHALL check, in the same AppleScript as the read, that this tab is still the window's current tab, and SHALL otherwise fail with the target-tab-changed error. When the window's current tab cannot be read at command start (a timeout under load, a window with no tab), the target stays unanchored and every poll resolves it afresh, without that check.
2. A URL-pattern target (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`) SHALL be followed through its window's URL list. The first poll SHALL compare that list with the one read while resolving; every later poll with the previous poll's. While the tabs to its left are unchanged and its position still shows the URL it showed before, the tab is read in place. When that URL is shown by exactly one tab, and by exactly one tab before, the tab has moved there and SHALL be read at the new position. When its position shows another URL, the tabs to its left and the tab count are unchanged, the tabs to its right did not all move one place left, and the URL it showed is either shown by no tab now or was shown by several tabs before, it navigated: its new URL is read and becomes the URL to follow. Anything else SHALL fail with the target-tab-changed error; in particular a URL that was shown by one tab and is now shown by several tabs is ambiguous and is not followed, and so is a tab that navigates to the URL its right neighbour shows (the observation is the same as the tab closing and a tab opening at the end).
3. `--document N` and `--window N --tab-in-window M` SHALL read the tab at that position in its window, and SHALL fail with the target-tab-changed error only when that position no longer exists.

Every poll SHALL probe for a blocking dialog on the window it reads, as every other URL read does. Waiting with `--timeout 0` or a negative value SHALL poll once.

#### Scenario: URL matches pattern

- **WHEN** user runs `safari-browser wait --for-url "dashboard"` and the current URL eventually contains "dashboard"
- **THEN** the CLI exits with zero status once the URL contains "dashboard"

#### Scenario: URL timeout

- **WHEN** user runs `safari-browser wait --for-url "never-match" --timeout 5000` and the URL never matches within 5 seconds
- **THEN** the CLI exits with non-zero status and stderr contains a timeout error

#### Scenario: Legacy `--url` syntax gets rename hint

- **WHEN** user runs `safari-browser wait --url "dashboard"` (pre-#23 syntax)
- **THEN** the CLI exits with non-zero status and the error message tells the user to use `--for-url` instead, explicitly mentioning that `--url` is now a targeting flag

#### Scenario: the target is resolved once

- **WHEN** user runs `safari-browser wait --for-url "/never" --url "plaud" --timeout 1200` and the wait polls three times
- **THEN** the window and tab enumeration SHALL run once, not once per poll

#### Scenario: the waited-for navigation happens in the target tab

- **WHEN** user runs `safari-browser wait --for-url "/done" --url "plaud"` and the tab named by `plaud` navigates to a URL containing `/done`
- **THEN** the wait SHALL exit with zero status, and SHALL NOT fail because the tab no longer matches `plaud`

#### Scenario: a tab to the left closes

- **WHEN** a `--url` target's tab is still on its page and a tab to its left closes, so its position changes
- **THEN** the wait SHALL keep reading that tab at its new position
- **AND** a tab that now sits at the old position SHALL NOT satisfy the wait

#### Scenario: a tab to the left closes while the target navigates

- **WHEN** a `--url` target's tab navigates in the same poll interval in which a tab to its left closes
- **THEN** the wait SHALL fail with the target-tab-changed error

#### Scenario: another tab becomes current

- **WHEN** the default target's window makes another tab current during the wait
- **THEN** the wait SHALL fail with the target-tab-changed error

#### Scenario: resolution outlasts the timeout

- **WHEN** resolving the target takes longer than `--timeout` and the condition already holds
- **THEN** the wait SHALL poll once and exit with zero status

#### Scenario: a poll outlasts the timeout

- **WHEN** a poll is still running when `--timeout` elapses, whether it is the first poll or one that started before the deadline
- **THEN** it SHALL NOT be interrupted or cancelled by `--timeout`, and its answer SHALL count: a condition that held in that poll ends the wait successfully
- **AND** no further poll SHALL start after the deadline, and the wait SHALL NOT ask to sleep past it

#### Scenario: the call that reads the URL reaches its own limit

- **WHEN** the call that reads the URL in a poll reaches its own time limit (a process timeout), or is a daemon request that was sent and not answered
- **THEN** the wait SHALL end with the error of that limit, unchanged, and SHALL NOT continue polling or report the timeout of `--timeout`

#### Scenario: a poll begins after the deadline was reached while sleeping

- **WHEN** polls are quick and the deadline falls while the wait sleeps between two polls
- **THEN** no poll SHALL start at or after the deadline

#### Scenario: a blocking dialog is reported on every poll

- **WHEN** a wait runs longer than the dialog probe's cache lifetime with the default target, `--window N`, or a `--url` target
- **THEN** the window SHALL be probed again after that lifetime, so a dialog that opens mid-wait is reported

---
### Requirement: Wait for JS condition

The system SHALL poll a JavaScript expression every 500 ms until it evaluates to a truthy value, then exit. The target SHALL be resolved once, before the first poll, and anchored as `js` anchors it: the default target and `--window N` are checked on every poll to still be the window's current tab (while the window's current tab could be read at command start, as the wait for a URL pattern states), a `--url` target keeps the per-poll URL check so that a navigation away from that URL fails the wait, and `--document N` and `--window N --tab-in-window M` name a position and are not identity-checked. A tab that has vanished SHALL fail with the target-tab-changed error, and SHALL NOT list the tabs of other profiles. The target SHALL be resolved once, before the first poll. Resolution time counts against `--timeout`, and the first poll SHALL always run, even when resolution used up the timeout. `--timeout` bounds when a poll after the first may start, and after an unsatisfied poll the wait SHALL ask to sleep no longer than until the deadline. It does not bound how long the command takes: resolving the target and a poll that has started are not cut short by `--timeout`, so the command can end later than it. The command's help SHALL say that the command can end later than `--timeout`. Each poll SHALL probe for a blocking dialog on the window it reads, as `js` does. `--timeout 0` or a negative value SHALL poll once.

#### Scenario: JS condition becomes true

- **WHEN** user runs `safari-browser wait --js "document.querySelector('.loaded')"` and the element eventually appears
- **THEN** the CLI exits with zero status once the expression is truthy

#### Scenario: JS condition timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 3000`
- **THEN** the CLI exits with non-zero status with a timeout error about 3 seconds after it started (later when a resolution or a poll is still running at the deadline)

#### Scenario: a JS poll outlasts the timeout

- **WHEN** a `--js` poll is still running when `--timeout` elapses, whether it is the first poll or one that started before the deadline, and its answer is truthy
- **THEN** it SHALL NOT be interrupted or cancelled by `--timeout` and the wait SHALL exit with zero status; no further poll SHALL start after the deadline

#### Scenario: a JS resolution outlasts the timeout

- **WHEN** resolving the target takes longer than `--timeout` and the condition already holds
- **THEN** the wait SHALL poll once and exit with zero status

#### Scenario: a daemon request of a `--js` poll is not answered

- **WHEN** the call that evaluates the expression in a `--js` poll is a daemon request that was sent and not answered
- **THEN** the wait SHALL end with the error of that limit, unchanged, and SHALL NOT continue polling or report the timeout of `--timeout`

#### Scenario: a zero or negative timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 0`
- **THEN** the wait SHALL poll once and exit with a timeout error

#### Scenario: the target is resolved once

- **WHEN** user runs `safari-browser wait --js "window.ready" --url "plaud" --timeout 1200` and the wait polls three times
- **THEN** the window and tab enumeration SHALL run once, not once per poll

#### Scenario: a position-named tab vanishes

- **WHEN** user runs `safari-browser wait --js "window.ready" --document 5` and that tab closes during the wait
- **THEN** the wait SHALL fail with the target-tab-changed error naming document 5

---
### Requirement: Default timeout

The system SHALL use a default timeout of 30000ms (30 seconds) for `--for-url` and `--js` wait operations when `--timeout` is not specified. The timeout has the meaning stated for the wait operations: it bounds when a poll after the first may start, not how long the command takes.

#### Scenario: Default timeout applied

- **WHEN** user runs `safari-browser wait --for-url "never"` without `--timeout`
- **THEN** the CLI times out after 30 seconds (the requirement above says when it can end later)

---
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
