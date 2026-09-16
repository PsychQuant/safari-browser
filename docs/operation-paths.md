# Operation paths: HID and non-HID

Most things this tool does can be reached more than one way. Clicking a button,
dismissing a dialog, choosing a file, exporting a PDF — each has a path that
drives the keyboard and mouse, and often a path that does not. This document
names those paths, records which one each operation currently takes, and states
the rule for choosing between them.

The rule is short: **when a non-HID path is proven to work, the HID path is
deleted, not kept alongside it.** "Proven" is not a judgement call — §2 defines
it as *measured*, and §3 spends most of its length on what the word has to mean
before it can license removing code. Everything below is either the evidence for
applying that rule, or the honest reason it cannot yet be applied.

---

## 1. What counts as HID

The distinction is whether the mechanism **synthesises input events** — events
indistinguishable from the user physically typing or clicking.

| Mechanism | What it sends | HID? |
|---|---|---|
| `keystroke "g" using {command down, shift down}` | synthetic key event | ✅ yes |
| `key code 53` | synthetic key event | ✅ yes |
| `click at {x, y}` | synthetic mouse event at a screen coordinate | ✅ yes |
| System Events `click <element>` | Accessibility `AXPress` action on that element | ❌ **no** |
| `perform action "AXConfirm" of <element>` | Accessibility action | ❌ no |
| `set value of <AXTextField> to "…"` | Accessibility attribute write | ❌ no |
| `URL of document 1`, `close window 2` | Apple Event to Safari | ❌ no — but see below; `activate` is also an Apple Event |

**The two `click`s are the trap.** System Events exposes `click` for both an
element reference and a screen coordinate. They share a name and mean opposite
things: `click <element>` asks the element to activate itself; `click at {x,y}`
injects a synthetic mouse event **at the coordinate you name**, regardless of
where the user's cursor is. Apple's own dictionary is explicit about the
parameter — `at` is "the { x, y } location at which to click, in global
coordinates". One goes through the element; the other goes around it and lands
wherever it was told to.

### Two properties, often confused

Non-HID does **not** mean "does not change anything". `AXPress` on a Cancel
button dismisses a dialog — that is a real state change. What it avoids is
narrower than it first looks: it never *fabricates an input event*, so it cannot
take a keystroke out of the user's hands mid-keypress.

It does not follow that a non-HID action is invisible to the user. Focus theft
is a consequence of what an action *does*, not of which mechanism dispatched it,
and every mechanism in the table above can cause it:

- A plain Apple Event is the bluntest of them. `tell application "Safari" to
  activate` and `set index of window N to 1` take the foreground outright, and
  they sit in the same row as the innocuous `URL of document 1`.
- `AXPress` can raise a sheet, and a sheet takes keyboard focus. `pdf` opens its
  export sheet with `click menu item "Export as PDF…"` — non-HID by the table
  above — and by the time the first keystroke fires, that sheet is already up and
  holding focus. `PdfCommand` does warn *"Controlling keyboard for PDF export"*
  before any keystroke, though not before the command has done anything: target
  resolution and, on a targeting flag, a tab switch both run first.

"Non-HID" is therefore a statement about one mechanism, not a safety certificate
for the operation built on it. There are at least two independent properties in
play:

| Property | Meaning | `AXPress` |
|---|---|---|
| **No synthetic input** | does not fabricate key or mouse events | ✅ satisfies |
| **State non-mutation** | changes nothing — including focus and window state | ❌ does not satisfy |

**This document's HID classification is decided by the first property alone.**
It is not a verdict on the
[Non-Interference principle](../openspec/specs/non-interference/spec.md), which
prohibits five separate things: synthetic mouse events, synthetic keystrokes,
system dialogs, audible feedback, and stealing window focus. Only the first two
are what "HID" names here. The other three still have to be assessed per
command, and a path this document calls non-HID can violate any of them — which
is why `AXPress`-based actions belong behind explicit opt-in rather than firing
automatically. Moving an operation onto a non-HID path is progress on one axis;
it does not discharge the interference triage.

---

## 2. Operation inventory

**Measured 2026-08-05.** For rows that have a candidate non-HID path, status is
one of three, and they mean different things:

- **proven** — a non-HID path was executed and produced the intended result
- **disproven** — a non-HID path was attempted and did **not** produce the result
- **untested** — no non-HID attempt has been made

`already non-HID` is not a fourth point on that scale — it marks rows where the
question does not arise, because there is no HID path to displace. The deletion
rule in §3 is correctly vacuous over them.

| Operation | Current implementation | Non-HID path | Permission | Status |
|---|---|---|---|---|
| Click a page element | `doJavaScript` `el.click()` | same | JS-from-Apple-Events | already non-HID |
| Read / fill / scroll | `doJavaScript` | same | JS-from-Apple-Events | already non-HID |
| Screenshot | AX bounds + `screencapture` | same | Screen Recording always; Accessibility only for `--element` / `--content-only` / explicit targeting | already non-HID (#23) |
| Switch tab / close window | AppleScript command | same | — | already non-HID |
| Upload a file, no flags, AX **not** granted | `doJavaScript` DataTransfer, capped at 10 MB | same | JS-from-Apple-Events | already non-HID |
| Upload a file, no flags, AX granted | the native dialog — see the *Open a native file dialog* and *Choose a file* rows | — | Accessibility | *(pointer row — status lives on the two rows it names)* |
| Dismiss a JavaScript dialog | `dialog dismiss --button` — `AXPress` (#103) | same | Accessibility | already non-HID |
| Cancel a native file dialog | `dialog dismiss --button` — same command | same | Accessibility | already non-HID |
| Probe a resolved target window before a document/native operation (#133–#138) | Stable window ID → bounded native AX walk; 200 ms total per logical command, no queued work while busy; default screenshot uses its resolved capture ID | same | Accessibility — denied, failed or incomplete reads remain unknown; WebArea contents are outside native-dialog scope | already non-HID — read-only, no `AXPress` |
| Open a native file dialog | `upload --native` opens it with `doJavaScript` `el.click()` | same | JS-from-Apple-Events for this step; `upload --native` as a whole needs Accessibility for the steps after it | already non-HID |
| **Choose an arbitrary file in that dialog** | file URL clipboard → AX Paste → named Upload when needed | same, without Go-to-Folder | Accessibility | **proven mechanism** on owned hidden/special paths; CLI completion verification remains under acceptance — see §4.1 |
| Choose an AX-exposed descendant from a confirmed ancestor | historical alternative; current native upload uses file URL Paste | Location menu → list mode → AXSelected/AXDisclosing → named Upload | Accessibility | **proven for the owned visible-tree case** (2026-09-14); not a generic path-replacement licence — see §4.1 |
| **Name the save destination for a PDF** | same keystrokes, via shared `SafariBridge.fileDialogNavigationScript` | AXValue of filename field → AXConfirm → named Save AXPress | Accessibility | **disproven** for this candidate (2026-09-13): slashes become colons and output remains in the old directory; other AX routes remain open — see §4.2 |
| Open the PDF export sheet | Unique File/檔案 → Export as PDF…/輸出為PDF⋯ menu item click | same | Accessibility | already non-HID — English and Traditional Chinese labels supported; Traditional Chinese exercised end to end on 2026-09-13; other locales fail explicitly |
| Confirm a native dialog sheet (Open / Save / "Replace?") | Unique enabled named Open/Upload/Save button, including supported Traditional Chinese labels; PDF destination replacement uses verified atomic publication with `--overwrite`, never a native Replace action | AX button press, including buttons in the sheet’s split group | Accessibility; PDF path entry still needs `--allow-hid` | **already non-HID** — owned Upload/Save/Replace exercised on 2026-09-13; initial confirmation Return fallback removed (#107). Path navigation is a separate row |

### Permissions do not track the HID split

The `Permission` column exists because the obvious inference from this document
is wrong. **`AXPress` and synthetic keystrokes go through the same System Events
channel and require the same Accessibility grant.** Moving an operation from the
HID column to the non-HID column does not lower the privilege it asks of the
user, and a reader who cannot take the non-HID path could not have taken the HID
path either.

Three prerequisites appear in the column, and one deliberately does not:

- **Accessibility** — every System Events operation, `AXPress` and keystroke
  alike, *and* the direct `AXUIElement` SPI that `screenshot` uses to read window
  bounds without System Events at all. `safari-browser setup` (#98) reports and
  requests it; the user-facing account is in [`README.md`](../README.md) under
  *Permissions*.
- **Screen Recording** — the pixel capture in `screenshot`, and nothing else.
- **JS-from-Apple-Events** — Safari's *Develop → Allow JavaScript from Apple
  Events* toggle, which `do JavaScript` requires and a plain AppleScript command
  (`close window 2`, `URL of document 1`) does not. It is the one prerequisite
  that splits the rows this table would otherwise mark `—`, and it is currently
  documented nowhere else in this repository — so a reader on a fresh machine
  meets a `do JavaScript` failure with no pointer. Worth fixing in `README.md`.
- **Apple events to Safari** is *not* recorded per row. Most rows need it, and
  the exceptions are not the interesting ones: a pure `AXPress` on an already-open
  dialog addresses its Apple event to *System Events*, which then drives Safari
  through Accessibility, and `screencapture` does not talk to Safari at all. It
  is a poor discriminator either way, so the column leaves it out rather than
  repeating it eleven times.

Rows marked `—` need none of the three.

The one place the privilege axis and the HID axis genuinely diverge is `upload`,
with Accessibility granted it takes the native AX/clipboard path, and without it
it falls to JS DataTransfer. Both avoid HID, but only the native path opens a
chooser, takes focus and temporarily uses the clipboard; the JS route remains
capped at 10 MB. See §3 for why both execution paths remain.

### How this was measured

Each dialog was produced inside a throwaway Safari window opened for the
purpose, measured, dismissed via `AXPress`, and the window closed — the user's
existing windows were never touched. The procedure is recorded in #97.

**There is currently no command that re-runs these measurements.**
`make test-reference-edges` is *not* it: that harness answers a different
question — which document reference form resolves correctly when the front
window has no tabs (#96) or carries a modal sheet (#83). It performs no
`AXPress`, enumerates no file-dialog accessibility tree, and probes no print
verb, so it cannot re-derive the status of a single row above. It is honest about
what it did not do — with no dialog present it prints `skip:` notes and ends with
`no failures (conditions not present count as skipped, not passed)` — but a green
exit is still what a reader following a "to re-measure" instruction would take
away. Re-measuring today means repeating #97's manual procedure.

**This table expires.** It describes one macOS and Safari version, and a status
of `disproven` may become reachable while a `proven` one stops being true. Two
cautions about the stamp itself:

- The environment recorded here is **macOS 27.0 (build 26A5388g) / Safari 27.0**,
  read from `sw_vers` and Safari's `CFBundleShortVersionString` on the machine
  that ran the measurements. But #97 and `Tests/e2e-reference-form-edges.sh:5`
  both record *Safari 26* for the same day and the same session. That
  contradiction is unresolved; this document restamped measurements it cites
  rather than ones it took, and an assigned stamp is worth less than a recorded
  one. Treat any row as version-suspect until re-measured with the build number
  written down.
- The expiry warning fences *reading* a row. It says nothing about a deletion
  already carried out on the strength of one — see §3.

---

## 3. Choosing a path

> **When a non-HID path is proven, delete the HID path.**

Note the precondition. The rule licenses deletion only against a row marked
**proven**. A row marked `untested` has not earned it; a row marked `disproven`
withholds it. Deleting an HID path because the rule "says so", without a proven
replacement, removes a working capability and replaces it with nothing.

`disproven` withholds the licence — it does not close the question. The status
records that one attempt failed, which is not the same as establishing that no
non-HID path exists. §4.1 records the failed visible-tree replacement and the later file URL Paste route that covered hidden paths and an unrelated starting directory.

The rule has now been applied to native file confirmation (#107). On
2026-09-13 the owned Upload, Save, and Replace fixtures established named AX
button presses, so the initial-confirmation Return fallback was removed. That
row is now `already non-HID`; the remaining Go-to-Folder keystrokes belong to
PDF destination row. Upload path selection now has its own file URL evidence
in §4.1; that evidence is separate from the #107 confirmation measurement.

Initial confirmation searches the file sheet's direct buttons and split-group
buttons for one enabled `Open`, `Upload`, `Save`, `打開`, `開啟`, `上傳`, or `儲存`
button. Missing, ambiguous, disabled, and unsupported-language buttons fail
explicitly. Safari must be frontmost and the sheet must exist without a nested
sheet. Neither a lookup failure nor a dispatched-click error sends Return.
The old `AXDefault` lookup missed the actual split-group buttons; an owned
production upload reproduced its Return fallback before this correction.

The file-dialog runner relays captured stderr on success, failure, and timeout
as a terminal-escaped trace, bounded to 4096 rendered scalars with explicit
truncation. It arrives **after subprocess completion**, records attempted
actions rather than their success, and is separate from the applicable interference
warning emitted before GUI interaction. Previously, successful subprocess
stderr was discarded despite the AppleScript `log` statements.

The caller's native file operation authorizes initial confirmation for the
specified path. PDF replacement requires the additional `--overwrite` flag;
`--allow-hid` alone does not authorize it. Existing effective destinations are
refused before GUI interaction without that flag; late destinations are preserved
by atomic no-replace. Safari writes to a unique private staging `.pdf`, so any
additional native confirmation is refused regardless of overwrite authorization.
The independent verified snapshot replaces the final directory entry only after
native sheet closure. A leaf symlink is replaced without writing its referent;
directories, links to directories, and special files are refused. See the named
exception in the [non-interference specification](../openspec/specs/non-interference/spec.md).

The owned upload fixture checked the page's file count, filename, and content.
The PDF fixtures checked the requested output path and `%PDF-` content, including
replacement of an owned sentinel. Those #107 measurements observed writes after
CLI return; #160 changes the completion contract to require native sheet closure
and a validated independent PDF snapshot before publication. The original
measurements alone do not validate that new lifecycle. These measurements do not resolve #101's file
selection alternatives or #102's remaining destination and isolated Print
experiments.

The two dialog rows are worth a note, because they moved. They were `proven`
while no command existed to act on them; #103 then shipped `dialog dismiss`,
which uses the proven `AXPress` route from the start. So they are now
`already non-HID` rather than newly deletable — the rule never fired on them,
because there was never an HID implementation to displace. A row reaching
`proven` is not by itself an event; what matters is whether an HID path exists
on the other side of it.

**Deletion is the one step this document cannot take back.** §2's expiry warning
tells you to re-measure before *relying* on a row. Nothing tells you what to do
when a row you already deleted against stops being true — the code is gone, and
re-measuring finds only its absence. Before acting on a `proven` row, record what
was actually proven and on which build; the strength of the evidence should be
proportional to the irreversibility of the action, and one measurement on one
machine is thin support for a permanent removal.

### Why delete rather than keep as a fallback

Keeping both is the tempting compromise, and it is worse than either option
alone:

- **Two paths are two behaviours** to maintain, test, and reason about — and one
  of them is already known to be worse.
- **A retained path becomes a fallback, and a fallback that fires silently is
  worse than no fallback.** The caller believes they took the safe route; the
  tool quietly took the other one, and the substitution only shows up as a stolen
  keystroke minutes later. Announcing the substitution is the mitigation, which is
  why this bullet argues against *silence* rather than against every second path.
  This repo does some of each, and **nobody has inventoried which is which** — so
  take these as examples, not as a tally. Announced: `upload` swapping the JS
  route for the native one (`ℹ️ Using JS DataTransfer` — an explicit `--js` prints
  nothing and needs to print nothing, since no substitution occurred), and the
  daemon's `[daemon fallback: <reason>]`. Initial file-dialog confirmation is recorded through the bounded trace after
  subprocess completion; lookup and click errors have no Return fallback. `screenshot` choosing between the AX and the
  legacy window resolver (§5) remains an example without that route diagnostic.
  The pre-GUI interference warning and the later mechanism trace serve different purposes.
  Until the inventory exists
  this document should not claim the repo mostly keeps the discipline; it claims
  only that the discipline is the right one.
- **HID conflicts with Non-Interference directly.** It moves the cursor, takes
  focus, and races whatever the user is doing. A path that does this is not a
  peer of one that doesn't.
- **`--allow-hid` is a false choice when a proven alternative exists.** Where the
  flag is a real gate it offers "dangerous" or "unavailable", and when a third
  option exists, making the user pick between the first two is a design failure
  rather than a safety feature. Note it is only a gate on `pdf`, which hard-fails
  without it. On `upload` the flag gates nothing — with Accessibility granted the
  native AX path is already the default and no flag is involved, which is the
  inversion §2 records.

### The one live case: why `upload` keeps both paths

`upload` ships two paths side by side and picks between them at runtime on
`AXIsProcessTrusted()`. Read against the bullet above, that looks like exactly
the arrangement this section condemns — so it is worth saying why the rule does
not fire, rather than leaving the document's clearest counter-example unmentioned.

The rule fires when a non-HID path **achieves the same result**. The JS
DataTransfer route does not: it is hard-capped at 10 MB
(`UploadCommand.swift`, `jsHardCapBytes`), so for an 11 MB file it is not a
worse way to do the job, it is unable to do the job. Two paths with different
domains are not a path and its fallback; they are two operations that share a
command name. The rule has nothing to delete here, and the honest description is
the one the code already prints to stderr when it takes the JS route.

This is also why the substitution must stay loud. A user whose 11 MB upload
silently became a 10 MB refusal, or whose fast native path silently became the
slow one, has been told something false about what happened.

### Where the rule does not reach

The rule governs *how* an operation is performed, not *whether* it happens
automatically, and not whether it interferes. A non-HID action can still raise a
sheet, take focus, or surprise the user — see §1. Commands whose effect the user
should consciously authorise stay behind explicit opt-in regardless of which path
they use; `setup` (#98) and the proposed `dialog dismiss` (#103) are both non-HID
**and** opt-in, for different reasons.

Nor does the rule cover *new* HID paths. Any command added later that takes one
must be recorded in §4 with a named reason and a tracking issue — an inventory
that only documents the exceptions someone happened to notice decays into a list
of historical curiosities.

---

## 4. Exceptions and open questions

### 4.1 Choosing a file — file URL Paste and named Upload

The current native upload implementation uses a file URL pasteboard item,
AXPress on the unique Edit/Paste item, and a named Upload/Open button when the
owned chooser remains open. It no longer emits Cmd+Shift+G, Cmd+V, Return, or
mouse events. The native route still needs Accessibility, foreground ownership
and a temporary clipboard change; non-HID does not mean non-interfering.

**Mechanism evidence, 2026-09-17:** on macOS 27.0 (26A428), Safari 27.0
(22625.1.29.11.27), owned fixtures exercised a hidden file in a hidden folder,
and selection from a chooser whose Location value was read back as Macintosh
HD. The latter also passed with Chinese characters, spaces and an apostrophe in
the path. Page file count, full filename and nonce content matched. The chooser
and owned window were cleaned up and the previous clipboard restored. See the
[file URL evidence](https://github.com/PsychQuant/safari-browser/issues/101#issuecomment-5704705980).

Paste alone is not a completion signal: several cases reached the target
folder but still needed the named Upload action. During Edit menu tracking,
Safari AppleEvents can block. The implementation uses AX-only owner checks in
that interval and explicitly cancels its own Edit menu once before resuming
page checks. `AXSelected` was false and the menu object still existed both
before and after Paste in the measured environment; those properties do not
establish whether tracking ended.

The clipboard lease snapshots all readable items/types up to 64 MiB, refuses an
incomplete snapshot, and restores only while its changeCount is still owned.
Observed newer content is preserved and reported. Cooperating native uploads
are serialized with a per-process registry and a per-user advisory lock, so
one upload does not snapshot another's temporary file URL as original content.
The operating system offers no cross-process compare-and-swap: arbitrary
clipboard writers can still race the final check/write, and forced termination
cannot guarantee restoration.

The script captures its native window ID, tab index, page nonce and original
file input. It rejects ownership/focus changes, unrelated or nested sheets,
ambiguous or disabled buttons, and expired deadlines without a keyboard
fallback or replay. Completion requires sheet closure, a trusted change on the
same input, and matching selected-file metadata. Cancelling a chooser with an
already matching old File is not a new successful upload; reselecting the same
file without a fresh change event is an explicit unverified outcome.

**CLI acceptance remains in progress:** the integrated CLI delivered the
correct owned filename/content, but its final metadata check returned a
mismatch. Field-specific diagnostics and size/mtime capture are prepared for
the next live run. This is not yet a verified production delivery; the
prototype evidence above must not be confused with that remaining check.

Historical candidates remain useful negative evidence:

| Candidate | Scoped result |
|---|---|
| Write a full path into the search field and AXConfirm | Did not select the requested file |
| Column AXList `AXSelectedChildren`, or file `AXOpen` | Advertised capabilities returned -25205 in tested calls |
| Column filename `AXConfirm` / `AXPress` | Acknowledgements did not prove selection; an A/B case uploaded the baseline |
| List-row `AXSelected` and folder `AXDisclosing` | Complete visible-tree traversal worked; tested hidden entries were not exposed |
| `AXReplaceRangeWithText` or browser focus setter | Did not establish a direct path-entry route |
| Plain-text clipboard Paste | Became enabled, but controlled cases did not establish complete upload |

These failures never proved that every non-HID route was impossible. Native
file URL clipboard objects differ from path text. The earlier visible-tree
measurement also lost selection when switching back to column view before
Upload; the current route does not switch view modes. See the
[list selection evidence](https://github.com/PsychQuant/safari-browser/issues/101#issuecomment-5655838750)
and [visible-tree limits](https://github.com/PsychQuant/safari-browser/issues/101#issuecomment-5661369453).

The PDF destination problem in §4.2 remains separate: selecting an existing
file URL does not demonstrate naming a new PDF destination without HID.

### 4.2 Naming a PDF's save destination — direct filename-path candidate disproven

**`PdfCommand` does not drive `Cmd+P`.** It opens the export sheet by
clicking the unique `Export as PDF…` / `輸出為PDF⋯` item in the `File` / `檔案`
menu. This is an AX element click, not HID. The Traditional Chinese hierarchy
was measured and exercised end to end on 2026-09-13. The earlier English-only
specifier failed immediately on this system; the current implementation
explicitly supports these two sets of labels and fails for others. It never
falls back to Print or a keyboard shortcut.

The largest HID residue is one step later: `PdfCommand` uses the shared
`SafariBridge.fileDialogNavigationScript` fragment to enter the save destination
with `Cmd+Shift+G` → `Cmd+V` → `Return` inside its single export script. The
initial named-button confirmation does not use Return. Final destination
replacement is handled through atomic filesystem publication under `--overwrite`;
no native Replace confirmation is dispatched. Retiring `--allow-hid` still needs evidence covering
path entry.

This matters for how the remaining work is scoped, and there are two separate
open questions rather than one:

- **Can the save panel's destination be entered without keystrokes?** This is the
  one that gates `--allow-hid`, and it is measurable *today* — the shipping
  `Export as PDF…` route already opens that panel, so nothing has to be built or
  routed around first. The direct filename-field candidate was tested below;
  other AX destination-navigation techniques remain unproven.
- **Is there a locale-independent way to open the export sheet?** Separate
  problem, separate motivation: the current menu-item route supports English
  and Traditional Chinese labels (see above), so wider locale support is not
  about retiring the flag.

The route #102 originally proposed — an `AXPress` on the print sheet's PDF popup
to reach "Save as PDF" — belongs to the second question, not the first. On the
face of it, it would land in the same save panel and remove no keystroke. That is
a prediction, not a measurement: nobody has enumerated the print sheet's
accessibility tree either.

Two further notes on the scripting-definition argument, since it is what makes
`print` look promising:

- Safari's own scripting definition declares **ten** commands (five of them
  `hidden="yes"`), none of which is `print`, `save`, or `export`. It does inherit
  the Cocoa Standard Suite via `xi:include`, which is where `print` would come
  from.
- **Do not read a successful `osacompile` as evidence for this.**
  `osacompile -e 'tell application "Safari" to print document 1'` compiles — but
  so does the same line addressed to `Dock`, which has no `print` command, and to
  an application name that does not exist at all. `print` and `save` are global
  Standard Suite terminology and compile against anything; only application-
  specific terms discriminate (`do JavaScript` compiles against Safari and fails
  against Dock with `-2740`). A nonsense verb failing proves only that the
  identifier is unknown to AppleScript, which is a different question. The probe
  is inert here.
- Even the `xi:include` is weaker evidence than it looks: it inherits
  *terminology*, not an implementation. An application can declare a Standard
  Suite verb and still return `errAEEventNotHandled` at runtime. So "Safari has a
  `print` verb" is a claim about its dictionary, not about its behaviour.
- What remains unknown is therefore both whether `print` is handled at all and
  whether it can be aimed at a file rather than a printer. **Testing has a real
  side effect**: wrong parameters may send an actual print job. It needs a
  deliberate, isolated experiment, not a casual probe during other work.

**Measured 2026-08-07 on the print panel** (raised with `print … with print
dialog`, which shows the panel without printing). The panel exposes an
`AXMenuButton` for PDF whose menu — opened with `AXShowMenu` — contains
*"儲存為PDF⋯"* with `AXPress` and `AXPick` among its actions. So that step is
reachable without a keystroke.

It does not retire `--allow-hid`, and the reason is the one predicted before the
measurement: pressing it opens a **save panel**, and entering the destination
there is the step that currently needs keystrokes. The route ends one step short
of the problem.

> **A caution earned the hard way.** The measurement that produced the menu
> listing also sent a print job. `AXShowMenu` opened the menu, the `osascript`
> process then exited, and the menu could not survive the process boundary —
> whatever tore it down appears to have triggered the panel's default button. No
> keystroke was sent and nothing pressed *"列印"* deliberately. The lesson
> generalises past this row: opening a modal through Accessibility is not a
> read-only act, and it must be closed inside the same script that opened it —
> the same cross-invocation gap that #15 and #106 are about.

**2026-09-13 direct Save-panel measurement.** A unique nonce page opened
through the Export menu exposed a writable filename AXTextField, separately
from Search and Tags. Writing an absolute path into its AXValue read back
exactly; AXConfirm returned successfully but did not save. Pressing the unique
named Save button then produced a valid PDF, but Safari replaced the path's
slashes with colons and wrote that literal filename in the panel's previous
directory. The requested destination remained absent. The owned test output
was recovered into the private fixture directory and removed from that wrong
location; every owned panel and window was cleaned up.

This disproves **that candidate**, not all AX destination navigation. A Save
button that closes its panel proves neither the intended directory nor the
requested file exists. Native upload's Open-panel selection is a separate
problem (#101); the direct filename-field failure does not settle it.

The `print ... with properties {...}` experiment remains unperformed: the user
confirmed on 2026-09-13 that no isolated macOS test host/VM is available. The
historical accidental print job is reason to retain that isolation requirement,
not evidence that PDF redirection is impossible. #102 remains open, and
`--allow-hid` remains required for the current destination-navigation path.

---

## 5. Relationship to Foresay P02

This document is an instance of **P02 Multi-Representation** from Foresay
(`kiki830621/foresay` v5.0.0 — a private repository, so this is a citation
rather than a link; the path below is relative to that repo root:
`00_principles/pragmatics/P02_multi_representation.md`):

> Every computational entity exists simultaneously in **multiple
> representations**, and clear communication requires naming which one is meant.
> […] Ambiguity *between representations* is a primary source of
> misunderstanding, distinct from ambiguity between senses.

An operation's execution paths are representations of one intent, and P02's
three disciplines map directly onto this file:

| P02 discipline | Here |
|---|---|
| **Name the representation** | §2 records, per operation, which path is taken — "clicked the button" is not a complete statement |
| **Document transitions** | `upload` reports its native/JS route at entry; the 10 MB JS limit is not a runtime fallback for a larger native upload. Initial Open/Save confirmation now records the unique named button; lookup and click errors do not send Return. File-dialog subprocess traces are escaped and bounded, then relayed on success, failure, or timeout after the subprocess finishes. This timing is separate from the pre-GUI keyboard warning. These examples do not establish a complete inventory of every command's fallback; see §3. |
| **Debug along the chain** | locating *which path* failed is half the diagnosis — #67 is precisely a failure localised to one path |

### What this repo adds on top of P02

Two things here are this repo's, not P02's, and should not be attributed to it:

**A preference order with elimination.** P02 requires naming which
representation is meant; it does **not** rank them. This document treats the
paths as ordered rather than as equivalent alternatives left standing, and
deletes the worse one once the better is proven. That ordering is a
safari-browser rule justified by the Non-Interference principle.

That is the only addition. An earlier draft of this section also claimed that
treating execution paths as representations *widened* P02's notion — that P02
covered representations of one entity while this covers implementations of one
intent. That was wrong, and wrong in the direction of false modesty: P02's own
taxonomy already carries a row for the several renderings of a single operation,
and its second discipline speaks of them as the *same request* in more than one
representation. Execution paths are an instance of P02, not an extension of it.

---

## See also

- [`openspec/specs/non-interference/spec.md`](../openspec/specs/non-interference/spec.md) — the principle this document expands along the execution-path axis
- **#101** — list-row selection and visible-tree disclosure have succeeded; hidden paths and arbitrary starting directories remain unproven, so the generic upload keystrokes remain
- **#102** — naming the save destination for a PDF: the direct filename-path candidate failed; other routes and isolated Print testing remain open. Note the export *invocation* is already non-HID; only the save panel needs a route
- **#103** — `dialog list` / `dialog dismiss`: proven non-HID, no opt-in command yet
- **#67** — stuck native file dialog; the failure family that lives on the HID path
- **#98** — `setup`: the other command that deliberately raises a system dialog, and why that is not a contradiction

### File-confirmation acceptance limits (#106 / #107)

Owned Upload, Save, authorized Replace, and late-created-file refusal were
exercised on macOS 27.0 / Safari 27.0 on 2026-09-13. Upload checked the page's
file count, name, and content; PDF checked the requested `.pdf` path and actual
PDF bytes. All owned sheets and windows were cleaned up.

Those #107 results did not make CLI return a file-completion guarantee. That
script checked replacement once after 0.5 seconds, and a file write was observed
to finish after CLI return. The late-created-file test covered a prompt within
that interval, not a later prompt. [#160](https://github.com/PsychQuant/safari-browser/issues/160)
replaces that flow with a common deadline, owner and staging-name checks,
terminal sheet observation, coherent PDF snapshot validation, and a single atomic
publication. The #160 acceptance record supplies evidence for the new flow;
these older measurements remain scoped to the prior confirmation behavior.

A refused initial confirmation or late replacement can leave the native sheet
open. Cancel it in Safari before retrying. Neither refusal authorizes an
automatic extra confirmation.

### Verified PDF publication acceptance (#160)

On 2026-09-14, owned localhost fixtures on macOS/Safari 27.0 exercised new PDF,
extensionless output, explicit `.txt` output, authorized replacement of a sentinel,
and a destination created after the pre-GUI warning. Successful CLI returns
identified the actual path and `pdfinfo` immediately read the PDF; the late
sentinel remained byte-for-byte intact with a nonzero exit and no success output.
All owned sheets/windows were cleaned up. Two other trials lost focus before
path-entry keystrokes, failed without creating output, and required guarded
cancellation of their owned panels. These establish observed fail-closed behavior,
not complete GUI isolation against every timing race. Unit tests additionally
exercise source mutation/replacement during copy, independent inode publication,
atomic no-replace, invalid PDFs, deadline/cancellation, permissions and symlinks.
