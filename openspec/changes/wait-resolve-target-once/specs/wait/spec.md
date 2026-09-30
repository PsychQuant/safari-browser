## MODIFIED Requirements

### Requirement: Wait for URL pattern

The system SHALL poll the URL of the target tab every 500 ms until it matches the given pattern, then exit. The `--for-url` flag accepts the pattern. (The previous `--url` flag was repurposed as a global targeting flag in #23 — see the `document-targeting` capability.)

The target SHALL be resolved once, before the first poll. The first poll SHALL always run, even when resolution used up the timeout; resolution time counts against `--timeout` but is not interrupted by it, and neither is a poll. `--timeout` bounds when a poll after the first may start (the first always runs), not how long the command takes: the command can end after the timeout by as much as the calls in flight at the deadline take (a resolution still running, the first poll, or a poll that started before the deadline). Each AppleScript call has its own limit: 30 s on the stateless path, where the process is terminated; on the daemon path the client waits at most 15 s, and a call already sent that is not answered by then fails with an outcome-unknown error, without a retry and without falling back (only a failure before the request is sent falls back to the stateless path). A call that reaches its limit ends the wait with that call's own error; the wait does not go on polling. After an unsatisfied poll the wait SHALL sleep no longer than until the deadline. The command's help SHALL say that the command can end later than `--timeout`. Which tab is read is decided by the target form, a closed list:

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

- **WHEN** an AppleScript call of a poll reaches its own limit (a process timeout, or the daemon client's 15 s)
- **THEN** the wait SHALL end with that call's error, not continue polling and not report the timeout of `--timeout`

#### Scenario: a blocking dialog is reported on every poll

- **WHEN** a wait runs longer than the dialog probe's cache lifetime with the default target, `--window N`, or a `--url` target
- **THEN** the window SHALL be probed again after that lifetime, so a dialog that opens mid-wait is reported

### Requirement: Wait for JS condition

The system SHALL poll a JavaScript expression every 500 ms until it evaluates to a truthy value, then exit. The target SHALL be resolved once, before the first poll, and anchored as `js` anchors it: the default target and `--window N` are checked on every poll to still be the window's current tab, a `--url` target keeps the per-poll URL check so that a navigation away from that URL fails the wait, and `--document N` and `--window N --tab-in-window M` name a position and are not identity-checked. A tab that has vanished SHALL fail with the target-tab-changed error, and SHALL NOT list the tabs of other profiles. The first poll SHALL always run, even when resolution used up the timeout. `--timeout` has the meaning stated for the wait for a URL pattern: it bounds when a poll may start, an in-flight resolution or poll is not interrupted and its answer counts, and each call has its own limit. Each poll SHALL probe for a blocking dialog on the window it reads, as `js` does.

#### Scenario: JS condition becomes true

- **WHEN** user runs `safari-browser wait --js "document.querySelector('.loaded')"` and the element eventually appears
- **THEN** the CLI exits with zero status once the expression is truthy

#### Scenario: JS condition timeout

- **WHEN** user runs `safari-browser wait --js "false" --timeout 3000`
- **THEN** the CLI exits with non-zero status after 3 seconds with a timeout error

#### Scenario: the target is resolved once

- **WHEN** user runs `safari-browser wait --js "window.ready" --url "plaud" --timeout 1200` and the wait polls three times
- **THEN** the window and tab enumeration SHALL run once, not once per poll

#### Scenario: a position-named tab vanishes

- **WHEN** user runs `safari-browser wait --js "window.ready" --document 5` and that tab closes during the wait
- **THEN** the wait SHALL fail with the target-tab-changed error naming document 5
