## MODIFIED Requirements

### Requirement: Wait for URL pattern

The system SHALL poll the URL of the target tab every 500 ms until it matches the given pattern, then exit. The `--for-url` flag accepts the pattern. (The previous `--url` flag was repurposed as a global targeting flag in #23 — see the `document-targeting` capability.)

The target SHALL be resolved once, before the first poll. The first poll SHALL always run, even when resolution used up the timeout; resolution time counts against `--timeout`. `--timeout` bounds when a poll after the first may start; it does not bound how long the command takes, and nothing that is running is interrupted or cancelled: the command can end after the timeout by what is still running at the deadline takes to finish — a resolution or a poll in progress, or, when the resolution outlasted the deadline, the whole first poll, which starts after it. Every AppleScript call has its own limit: 30 s on the stateless path (the process is terminated, and killed after a further 1 s if it does not exit); on the daemon path the client waits at most 15 s for the answer to a request it has sent, and a request that is not answered fails with an outcome-unknown error, without a retry and without falling back, whereas a failure before the request is sent falls back to the stateless call, so that call can take 15 s and then up to 30 s more. A poll can make more than one call. A poll's call that reaches its limit ends the wait with that call's own error (with the blocking-dialog error instead, when a dialog is found on the window); the wait does not go on polling. Calls that resolve the target have shorter limits and degrade instead of failing: the read of the window's current tab (2 s) and of its window id (1 s) leave the target unanchored (item 1 below). After an unsatisfied poll the wait SHALL sleep no longer than until the deadline. The command's help SHALL say that the command can end later than `--timeout` and give the limits of a call. Which tab is read is decided by the target form, a closed list:

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
- **THEN** it SHALL NOT be interrupted or cancelled, and its answer SHALL count: a condition that held in that poll ends the wait successfully
- **AND** no further poll SHALL start after the deadline, and the wait SHALL NOT sleep past it

#### Scenario: a call reaches its own limit

- **WHEN** an AppleScript call of a poll reaches its own limit (a process timeout on the stateless path, or a daemon request that was sent and not answered)
- **THEN** the wait SHALL end with that call's error, unchanged, not continue polling and not report the timeout of `--timeout`

#### Scenario: a poll begins after the deadline was reached while sleeping

- **WHEN** polls are quick and the deadline falls while the wait sleeps between two polls
- **THEN** no poll SHALL start at or after the deadline

#### Scenario: a blocking dialog is reported on every poll

- **WHEN** a wait runs longer than the dialog probe's cache lifetime with the default target, `--window N`, or a `--url` target
- **THEN** the window SHALL be probed again after that lifetime, so a dialog that opens mid-wait is reported

### Requirement: Wait for JS condition

The system SHALL poll a JavaScript expression every 500 ms until it evaluates to a truthy value, then exit. The target SHALL be resolved once, before the first poll, and anchored as `js` anchors it: the default target and `--window N` are checked on every poll to still be the window's current tab, a `--url` target keeps the per-poll URL check so that a navigation away from that URL fails the wait, and `--document N` and `--window N --tab-in-window M` name a position and are not identity-checked. A tab that has vanished SHALL fail with the target-tab-changed error, and SHALL NOT list the tabs of other profiles. The paragraph of the wait for a URL pattern that begins "The target SHALL be resolved once" applies to this wait in every sentence, with the JS poll in place of the URL read: the first poll always runs, `--timeout` bounds only when a poll may start, nothing running is interrupted or cancelled and a poll's answer counts, a call has its own limit and a call that reaches it ends the wait with its error, the wait sleeps no longer than until the deadline, and the command's help says so. Each poll SHALL probe for a blocking dialog on the window it reads, as `js` does. `--timeout 0` or a negative value SHALL poll once.

#### Scenario: JS condition becomes true

- **WHEN** user runs `safari-browser wait --js "document.querySelector('.loaded')"` and the element eventually appears
- **THEN** the CLI exits with zero status once the expression is truthy

#### Scenario: JS condition timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 3000`
- **THEN** the CLI exits with non-zero status with a timeout error, about 3 seconds after it started (later only by what was still running at the deadline)

#### Scenario: a JS poll outlasts the timeout

- **WHEN** a `--js` poll is still running when `--timeout` elapses, whether it is the first poll or one that started before the deadline, and its answer is truthy
- **THEN** it SHALL NOT be interrupted or cancelled and the wait SHALL exit with zero status; no further poll SHALL start after the deadline

#### Scenario: a JS resolution outlasts the timeout

- **WHEN** resolving the target takes longer than `--timeout` and the condition already holds
- **THEN** the wait SHALL poll once and exit with zero status

#### Scenario: a JS poll reaches its own limit

- **WHEN** the AppleScript call of a `--js` poll reaches its own limit
- **THEN** the wait SHALL end with that call's error, unchanged, and SHALL NOT continue polling

#### Scenario: a zero or negative timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 0`
- **THEN** the wait SHALL poll once and exit with a timeout error

#### Scenario: the target is resolved once

- **WHEN** user runs `safari-browser wait --js "window.ready" --url "plaud" --timeout 1200` and the wait polls three times
- **THEN** the window and tab enumeration SHALL run once, not once per poll

#### Scenario: a position-named tab vanishes

- **WHEN** user runs `safari-browser wait --js "window.ready" --document 5` and that tab closes during the wait
- **THEN** the wait SHALL fail with the target-tab-changed error naming document 5

### Requirement: Default timeout

The system SHALL use a default timeout of 30000ms (30 seconds) for `--for-url` and `--js` wait operations when `--timeout` is not specified. The timeout has the meaning stated for the wait operations: it bounds when a poll may start, not how long the command takes.

#### Scenario: Default timeout applied

- **WHEN** user runs `safari-browser wait --for-url "never"` without `--timeout`
- **THEN** the CLI times out after 30 seconds, later only by what was still running at the deadline

