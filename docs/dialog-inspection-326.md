# Scoped dialog inspection (#326)

## What is established

The change starts from main `ad317f9`. The global scanner shares one deadline
across all windows and requires a complete scan before accepting one candidate.
An unreadable unrelated native tree therefore prevents dismissal of an otherwise
readable confirm. The regression fixture reproduces this and the scoped path
avoids it without weakening completeness inside the selected window.

Issue #326 also reports a visible Safari 27.2 card with no corresponding System
Events sheet or named button. That observation does **not** establish where the
native AXUIElement tree exposes the card, or whether it exposes it at all. This
change does not claim to fix that second failure. It must remain a draft until
macOS compilation and native acceptance are completed; do not close #326 yet.

PR #200 remains open and changes the entry probe's viewport classification and
attribute reads. It is not incorporated here. The current global scanner still
excludes AXWebArea descendants, preventing web ARIA dialogs from supplying native
confirmation buttons. Root AXDialog / AXSystemDialog candidates remain
conservative candidates; a root with no buttons is not guessed to be harmless.

## Commands and limits

```sh
safari-browser dialog list --window-id 42
safari-browser dialog dismiss --window-id 42 --button '好'
```

Use an observed stable Safari ID, not z-order or a window index. The
`blocking_dialog.window_id` field of `documents --json` can supply this identity
when its observation succeeds; `null` is not usable. A caller that already owns
a native target can use its known stable ID. No identity fallback is performed.

For a caller-bound message, the existing paired expectation also selects scope:

```sh
safari-browser dialog dismiss --expect-window-id 42 \
  --expect-message '新增這筆資料。確定嗎？' --button '好'
```

The message above is illustrative: pass the actual raw message, including any
Safari heading, not a guess copied from a screenshot. Rendered terminal fields
can be escaped/truncated, so do not treat them as a lossless raw-message API.

All bounded window identities must be readable, positive and unique. Only the
selected native tree is then traversed, and its ID is rechecked after traversal.
Other windows' role/subrole/children reads consume no traversal budget in this
mode. Window enumeration or ID timeouts still refuse; they are not treated as
successful target selection. A missing target is incomplete, never "no dialog".

Without a scope flag the complete global scan and global ambiguity rule remain.
With a scope flag ambiguity is evaluated inside that window. Both modes bind the
press to the initial observation's ID and re-read the message and ordered buttons
synchronously. Changed content, missing/duplicate names, incomplete details,
session/deadline failure and multiple target candidates cannot authorize AXPress.
AXPress and preceding AX reads are not an atomic transaction; this does not claim
to eliminate every possible UI race or distinguish identical replacement dialogs
inside the same window.

The old global `no blocking dialog found` stdout and listing first line remain
for harness compatibility. A no-candidate result now adds native AX visibility
guidance on stderr. A visible but unexposed card requires manual handling; do not
replay the save/click, repeatedly retry the same scan, guess Return, or click by
coordinates. No fallback action was added.

## Verification performed in Linux

- `python3 Tests/portable-dialog-tests.py` with Swift 6.0.3 and a local
  swift-argument-parser 1.5.0 checkout: **58 XCTest cases, zero failures**.
  This stages real scanner, worker, observation, command/decision and rendering
  code, with inert macOS bridge/provider/session/daemon/trace boundaries. It is
  not a full application build and does not validate actual AX attribute reads.
- Scope-branch mutation: replacing the scoped branch condition with `false`
  caused `testUnrelatedUnreadableWindowDoesNotBlockExplicitTarget` to fail four
  assertions, including no press occurring. Restoring it passed the same case.
- `python3 Tests/current-dialog-harness-test.py`: **10 tests passed**. The live
  harness now uses `dialog list --window-id` before its existing exact-message,
  stable-ID guarded cancellation and checks that its handler ran once.
- Swift parser check on changed Swift files and `git diff --check`: passed.
- Spectra validation: passed; analyzer reported no Critical/Warning findings
  (three optional example suggestions).

Other attempted checks, not passes:

- `make test`: the downloaded Linux Swift runtime terminated with SIGILL. Other
  initial subset attempts also encountered SIGILL; the reproducible single-job
  runner subsequently completed. The runtime cause was not established.
- Direct full-project `swift test -j 1`: compilation fails with `no such module
  'Darwin'` on Linux. macOS compilation and the full suite remain required.
- `Tests/dialog-harness-test.py`: 14/16 passed; the two failures were
  `test_known_existing_dialog_remains_environment_skip` and
  `test_locked_session_skips_before_browser_calls`, both blocked by the existing
  harness's absolute `/usr/bin/uuidgen` dependency, absent in this environment.
- `Tests/background-dialog-harness-test.py`: 24/25 passed; the `inherit` subcase of
  `test_group_preflight_accepts_inheritance_and_refuses_escape_or_no_child`
  could not observe a directly nested wait process in this environment.

## Native acceptance still required

1. Build and run `make test` on macOS using the project's normal signed build
   workflow. Run `Tests/e2e-current-dialog.py` with an unlocked session and the
   new binary; exit 77 is a skip, not acceptance.
2. Use only owned fixture windows. Record exact Safari/macOS/build versions and
   window IDs. With several windows, verify a foreground and an inactive-window
   `window.confirm`, listing the exact localized labels before selecting either
   named button. Verify the handler count is one and its answer matches that
   selected button. The existing current-dialog harness exercises cancellation;
   acceptance (`好`) needs its own owned-fixture check.
3. Repeat scoped inspection with an unrelated AXDialog root in another window
   if that session reproduces the shape in #326. Verify unscoped ambiguity still
   refuses, and no unrelated window receives AXPress. Simulated tests cover this
   case, but they do not establish Safari's real root classification.
4. While the owned visible card remains open, inspect the native Accessibility
   hierarchy (not only System Events): role, subrole, AXModal where exposed,
   parent/child path relative to AXWindow / AXWebArea, message text attributes,
   button titles and supported actions. Record read errors and where traversal
   stops. Do not expand detection into web content without an evidenced way to
   distinguish native modal UI from page ARIA content.
5. If the card is still unexposed, stop automatic actions and hand it to the
   human. Attach the bounded owned-fixture observation to #326; keep this PR
   draft and treat Safari 27 detection as unresolved.
