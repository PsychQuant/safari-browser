# blocking-dialog-probe Specification

## Purpose

TBD - created by archiving change 'dialog-probe-correctness'. Update Purpose after archive.

## Requirements

### Requirement: Stable target probing
Entry probes SHALL identify the target by a positive stable window ID and match Accessibility windows by that ID. AX list order and a focused non-browser window MUST NOT select a different target. Missing identity or failed ID reads SHALL be unprobed. An already-resolved positive ID absent from the AX list SHALL remain unprobed even when that list is empty.

#### Scenario: AX order differs
- **WHEN** AppleScript target ID is 42 and AX windows enumerate IDs 9 then 42
- **THEN** only window 42 is used to decide whether the target is blocked.

---
### Requirement: Expiring keyed verdicts
Gate state and refusal SHALL require an explicit target key and a fresh monotonic timestamp. A verdict SHALL expire after its TTL. Clear SHALL be distinct from Optional.none. Unscoped failure attribution MUST NOT use another window's dialog.

#### Scenario: Switching targets and expiration
- **WHEN** A has a present verdict, B is checked, and A subsequently expires
- **THEN** B is never refused using A's verdict and expired A no longer authorizes refusal.

---
### Requirement: Bounded complete probing
The entry probe SHALL bound each caller wait below 100 ms and SHALL share a total 200 ms probe budget across one logical command and SHALL keep at most one AX worker in flight. A busy worker SHALL cause immediate unprobed without queuing. WebArea descendants SHALL be excluded from native UI inspection; a page ARIA dialog MUST NOT be treated as a native blocker. Deadline, failed native-UI reads, and unexamined truncated native-UI branches SHALL produce unprobed, never clear. Window chrome left out under Requirement: Window chrome exclusion is not a truncated branch. Late results MUST NOT modify a timed-out request's gate cache.

#### Scenario: Provider blocks
- **WHEN** window ID, role, children, text, or button reading stops responding
- **THEN** the caller returns unprobed within the waiting budget and a second request does not start another worker.

#### Scenario: Command exhausts its budget
- **WHEN** probes in one CLI command consume its 200 ms total budget
- **THEN** further uncached checks return unprobed without starting another probe, while a new daemon exec step receives its own 200 ms budget.

#### Scenario: Deep native dialog
- **WHEN** an AXDialog exists at depth 3 and all preceding reads succeed
- **THEN** the probe returns present.

---
### Requirement: Window chrome exclusion
This requirement covers the entry probe only. The global scanner (`dialog list`, `dialog dismiss`, `is dialog`, and the dialog state in `documents`, `tabs` and exec `documents` steps) shares the probe's dialog predicate but keeps its own rules for chrome and window roots (`global-dialog-inspection`); changing those is left to #326 (maintainer's scope decision on #328, 2026-11-01). The scanner therefore still sees everything the entry probe leaves out.

The entry probe SHALL NOT enter window chrome, neither while looking for a dialog nor while reading a found dialog's text and buttons. Window chrome is a closed list of three, matched exactly: role `AXToolbar`, whatever its subrole; role `AXOpaqueProviderGroup` with subrole `AXOpaqueProviderList` (the tab bar); role `AXRadioButton` with subrole `AXTabButton` (a tab). The chrome test SHALL come before the dialog test, so a toolbar is never the matched dialog whatever subrole it reports; a tab bar or tab that reported a dialog subrole instead of its own would not match the list and would be tested as a dialog. The toolbar is decided on its role alone, so a subrole read that fails on it does not make the walk incomplete. While reading a found dialog's text and buttons, a tab bar or tab whose subrole cannot be read is left out. A skipped chrome subtree is an exclusion, not truncation: it SHALL NOT make a walk incomplete, and it MUST NOT turn an otherwise incomplete walk into clear. Dialogs in the tab content and sheets that are children of the window SHALL still be found.

The entry probe SHALL NOT treat its target window itself as the blocking dialog, whatever role or subrole the window reports; only nodes below it can be. The target is a browser window, and on Safari 27.2 a JavaScript dialog appears below it (in the tab content), never as the window itself. #326 recorded an unrelated web page window reporting subrole `AXDialog`; reading such a window as a dialog collects the page title from the tab bar and the address field's controls from the toolbar — the shape #328 reported.

The list was measured on Safari 27.2 (2026-11-01, #328). The node behind the reported false positive was not reproduced. Two explanations fit it: the window itself reporting a dialog subrole, which is the stronger one (the page-title text sits in the tab bar and the four buttons in the toolbar; in every measured tree their only common ancestor is the window), or a transient node with a dialog subrole that spans both. This requirement covers both rather than naming one node. Known limits: a blocking sheet that a future Safari attached under the toolbar would go unreported by the entry gate (`dialog list` still sees it), and a genuine sheet's own tab view or toolbar is left out of the warning's text. Draft PR #200 (#187) changes how this walk reads nodes; the conflicts are recorded on #187.

#### Scenario: Dialog-like node in the chrome
- **WHEN** a node with a dialog role or subrole is inside the toolbar, the tab bar or a tab button, and nothing else in the window is a dialog
- **THEN** the entry probe returns clear.

#### Scenario: Target window reporting a dialog subrole
- **WHEN** the target window itself reports subrole `AXDialog`, its toolbar holds titled buttons, and nothing below the window is a dialog
- **THEN** the entry probe returns clear, not present with the toolbar's buttons.

#### Scenario: Content dialog after chrome
- **WHEN** the tab bar and the toolbar precede the content path, each holding a dialog-like node, and the content holds a dialog at depth 3
- **THEN** the probe returns present with the content dialog's own message and buttons.

#### Scenario: Window with many tabs
- **WHEN** the tab bar holds more tab buttons than the node budget and the rest of the window is read completely
- **THEN** the probe returns clear rather than unprobed. (On Safari 27.2 a normal window is not read completely yet: the page's scroll area sits at the depth limit, #187, so it still answers unprobed until that is fixed.)

---
### Requirement: Debug match path
A present verdict from the entry probe SHALL carry the path to the matched node: one element per level from the window down, each the role followed by `/` and the subrole when there is one. The path SHALL contain roles only, never titles, values or page text, and SHALL NOT take part in dialog equality. With `SAFARI_BROWSER_DIALOG_PROBE_DEBUG=1` the debug line SHALL print `present at <path>`, elements joined by ` > `, escaped as one line.

#### Scenario: Naming a false positive
- **WHEN** debug is on and the probe matches a group with subrole `AXDialog` under the window's split group and tab group
- **THEN** the debug line ends with `→ present at AXWindow/AXStandardWindow > AXSplitGroup > AXTabGroup > AXGroup/AXDialog` and contains none of the dialog's text.

---
### Requirement: Native command warnings
Targeted native operations SHALL invoke the gate after target resolution and before acting. This includes close, pdf, tab focus, upload, save-image, ordinary screenshot, and tabs with an explicit window. Warnings SHALL remain on stderr and MUST NOT by themselves fail a read-only operation.

#### Scenario: Window tab listing
- **WHEN** tabs --window resolves a window that has a blocking dialog
- **THEN** it emits the warning on stderr and retains its existing stdout format.

---
### Requirement: Honest probe tests
The test harness SHALL reject unavailable timing dependencies and malformed timing values before arithmetic. It SHALL distinguish environment skips from CLI errors, assert the measured probe budget, and verify ownership before dismissing a fixture dialog. Unit tests SHALL cover failed reads, incomplete traversal, Unicode line folding, and debug values.

#### Scenario: Invalid timing command
- **WHEN** timing fails or returns a non-integer
- **THEN** the harness fails rather than reporting a zero-millisecond pass.
