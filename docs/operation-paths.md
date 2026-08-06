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

So "non-HID" is a statement about one mechanism, not a safety certificate for the
operation built on it.

So there are at least two independent properties:

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
| Dismiss a JavaScript dialog | *(no such command yet — #103)* | `AXPress` on its button | Accessibility | **proven** |
| Cancel a native file dialog | *(no such command yet)* | `AXPress` on Cancel (nested inside the sheet; needs a recursive search) | Accessibility | **proven** |
| Open a native file dialog | `upload --native` opens it with `doJavaScript` `el.click()` | same | JS-from-Apple-Events for this step; `upload --native` as a whole needs Accessibility for the steps after it | already non-HID |
| **Choose a file in that dialog** | `Cmd+Shift+G` → `Cmd+V` → `Return` | none found yet | Accessibility | **disproven** — see §4.1 |
| **Name the save destination for a PDF** | same keystrokes, via `SafariBridge.navigateFileDialog` | none found yet | Accessibility | **untested** — see §4.2 |
| Open the PDF export sheet | `click menu item "Export as PDF…"` | same | Accessibility | already non-HID — **only where Safari's menus are English**; see §4.2 |

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
and it runs **opposite** to intuition: with Accessibility granted it takes the
keystroke path, and without it, it falls to the fully non-HID JS DataTransfer
route. See §3's note on why the deletion rule does not fire there.

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
non-HID path exists. §4.1 is `disproven` and still names an untried route.

**Applied to the table as it stands today, this rule licenses zero deletions.**
Every `already non-HID` row has nothing to displace; both `proven` rows describe
commands that do not exist yet (#103); `Choose a file` is `disproven`; the PDF
save destination is `untested`. That is worth stating plainly, because it bounds
every worry in this section to the future: no capability can be lost by this
document standing as written. The first row that becomes genuinely deletable is
the one to argue carefully about.

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
  daemon's `[daemon fallback: <reason>]`. Silent: `screenshot` choosing between
  the AX and the legacy window resolver (§5), and `keystroke return` standing in
  for a default-button click that threw, in `pdf` and `upload` alike (§4.2) — the
  keyboard warning does not cover that one, because it says the command will use
  the keyboard, not that the accessible route failed. Until the inventory exists
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
  keystroke path is already the default and no flag is involved, which is the
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

### 4.1 Choosing a file — no non-HID path found

`upload --native` uses `Cmd+Shift+G` → `Cmd+V` → `Return`
(`SafariBridge.swift`, `UploadCommand.swift`). This is **not** an oversight that
the rule can simply retire.

Measured attempt: with the file dialog open, its accessibility tree contains
exactly one `AXTextField` (offering `AXShowMenu` and `AXConfirm`). Writing the
full path into it **succeeded** (the value read back correctly), `AXConfirm`
**succeeded**, and pressing the Upload button **succeeded** — yet the page saw
`input.files.length === 0` and the sheet stayed open.

The working hypothesis is that the text field is the sidebar's search box, and
that the real path-entry field belongs to the **nested sheet `Cmd+Shift+G`
creates** — a sheet that does not exist until the keystroke is sent. If that is
right, the HID here is not laziness: the element being driven has to be summoned
by HID first. It would also fit the shape of #67 (`Go to Folder panel did not
appear within 10 seconds`), where the thing failing to appear is that same
nested sheet.

**It is a hypothesis, and the measurement does not single it out.** At least
three other readings fit the same evidence: an AX value write can be accepted and
stored by the accessibility layer without ever firing the control's action, so
"the value read back correctly" discriminates nothing; `AXConfirm` returning
success reports that the action was dispatched, not that it produced a
navigation; and the open panel runs out of process, so even a correct selection
need not yield a file URL the web content process can consume. The sheet staying
open is consistent with all of them. The check that would separate these is
read-only and cheap — the `AXRoleDescription`, placeholder, and parent chain of
that one `AXTextField` — and it has not been run.

What the status records is therefore narrow and exact: this attempt failed. Not
that no non-HID path exists.

Tracked in **#101**, which names an untried route: driving the dialog's file
browser (`AXOutline` / `AXBrowser`) to select the target directly, never needing
Go-to-Folder.

Note where a fix would have to land. The keystroke sequence is written once —
`SafariBridge.fileDialogNavigationScript` returns it as AppleScript text — but it
is *embedded* by two callers rather than *called* by them, because each has to
keep its flow inside a single `osascript` invocation (#15: two invocations leave
a window for another app to steal focus mid-sequence, and the keystrokes then
land somewhere else). So replacing the sequence means changing one generator, and
checking two embeddings still make sense around it (#105).

### 4.2 Naming a PDF's save destination — untested, and testing has side effects

**`PdfCommand` does not drive `Cmd+P`.** It opens the export sheet with
`click menu item "Export as PDF…" of menu "File" of menu bar 1` — a System Events
element click, which by §1 is an `AXPress` and **not** HID. The only `Cmd+P` in
this repository is a comment in `PdfCommand.swift`. So the invocation leg of PDF
export is already on the preferred side of this document's own rule.

**But only on an English system.** That comment is not a note about a road not
taken; it is a warning that the implemented route is locale-dependent: *"Menu
labels are English. On non-English macOS, use keyboard shortcut instead. `Cmd+P`
→ 'PDF' dropdown → 'Save as PDF' is locale-independent but more complex."* There
is no fallback in the code. On a system where Safari's menus are not in English,
`click menu item "Export as PDF…"` cannot resolve its object specifier, and since
nothing wraps that statement the script aborts there with an AppleScript `-1728`
— immediately, not after a wait. (The 10-second timeout in the same block guards
a *different* failure: the menu item resolved but no sheet appeared. The two are
mutually exclusive.) So the non-HID invocation is conditional on Safari's UI
language, and the locale-independent alternative the code itself names is the HID
one.

The largest HID residue is one step later: `PdfCommand` calls
`SafariBridge.navigateFileDialog`, which enters the save destination with
`Cmd+Shift+G` → `Cmd+V` → `Return`. It is not the only one — `PdfCommand` also
falls back to `keystroke return` in its "Replace?" confirmation branch, outside
`navigateFileDialog` entirely, and both `navigateFileDialog` and `upload`'s copy
carry the same `keystroke return` fallback when clicking the default button
throws. Retiring `--allow-hid` means clearing **all** of them, not just the path
entry.

This matters for how the remaining work is scoped, and there are two separate
open questions rather than one:

- **Can the save panel's destination be entered without keystrokes?** This is the
  one that gates `--allow-hid`, and it is measurable *today* — the shipping
  `Export as PDF…` route already opens that panel, so nothing has to be built or
  routed around first. It is `untested` because nobody has enumerated that
  panel's accessibility tree, not because it is blocked on anything.
- **Is there a locale-independent way to open the export sheet?** Separate
  problem, separate motivation: the current menu-item route is English-only (see
  above), so this one is about `pdf` working at all on a localised system, not
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

Tracked in **#102**. Note that this row and §4.1 share the *keystroke sequence*
but not necessarily the *problem*: `upload` drives an **open** panel and needs to
select an existing file, whereas `pdf` drives a **save** panel and needs to name
a destination, which a save panel would normally expose as an editable field
rather than something to be navigated to — though that, too, is unmeasured.
Techniques for the former do not automatically transfer to the latter, and the
save panel may well be the easier of the two. Solving #101 does not automatically
retire this row.

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
| **Document transitions** | the discipline this repo keeps unevenly, at different depths. `upload` keeps it at the **top level**: it decides between the native and JS routes on the Accessibility grant and prints which one it took. (It decides *once*, at entry; there is no runtime fallback from one to the other, and the code says so: "Note: --js (DataTransfer) is capped at 10 MB (#24), so it is not a fallback for large files.") Below that level it does not — nor does `pdf`: when a default-button click throws, both fall back to `keystroke return` without recording it. And `screenshot` does not keep it at the top level either: `resolveWindowForCapture` picks between the AX resolver and the legacy CG name-match on `AXIsProcessTrusted()`, the two differ in the permission they need and in their known failure modes, and nothing is printed either way. See §3 for why this is examples rather than an inventory. |
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
- **#101** — choosing a file in the open panel: one non-HID attempt failed, an untried route named (blocks retiring `upload`'s keystrokes)
- **#102** — naming the save destination for a PDF: non-HID feasibility untested. Note the export *invocation* is already non-HID; only the save panel needs a route
- **#103** — `dialog list` / `dialog dismiss`: proven non-HID, no opt-in command yet
- **#67** — stuck native file dialog; the failure family that lives on the HID path
- **#98** — `setup`: the other command that deliberately raises a system dialog, and why that is not a contradiction
