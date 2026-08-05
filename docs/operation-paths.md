# Operation paths: HID and non-HID

Most things this tool does can be reached more than one way. Clicking a button,
dismissing a dialog, choosing a file, exporting a PDF — each has a path that
drives the keyboard and mouse, and often a path that does not. This document
names those paths, records which one each operation currently takes, and states
the rule for choosing between them.

The rule is short: **when a non-HID path is proven to work, the HID path is
deleted, not kept alongside it.** Everything below is either the evidence for
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
| `URL of document 1`, `close window 2` | Apple Event to Safari | ❌ no |

**The two `click`s are the trap.** System Events exposes `click` for both an
element reference and a screen coordinate. They share a name and mean opposite
things: `click <element>` asks the element to activate itself; `click at {x,y}`
moves nothing but injects a mouse event wherever the cursor happens to be
pointed. One is invisible to the user, the other competes with them.

### Two properties, often confused

Non-HID does **not** mean "does not change anything". `AXPress` on a Cancel
button dismisses a dialog — that is a real state change. What it avoids is
touching the user's *input devices*: the cursor does not move, focus is not
stolen, and a keystroke the user types at that moment goes where they meant it
to go.

So there are two independent properties:

| Property | Meaning | `AXPress` |
|---|---|---|
| **Input-device non-interference** | does not move the cursor / steal focus / race the user's typing | ✅ satisfies |
| **State non-mutation** | does not change anything | ❌ does not satisfy |

The [Non-Interference principle](../openspec/specs/non-interference/spec.md) is
about the first. A command can be non-HID and still be actively interfering in
the second sense — which is why `AXPress`-based actions still belong behind
explicit opt-in commands rather than firing automatically.

---

## 2. Operation inventory

**Measured 2026-08-05 on macOS 27.0 / Safari 27.0.** Status values are limited
to three, and they mean different things:

- **proven** — a non-HID path was executed and produced the intended result
- **disproven** — a non-HID path was attempted and did **not** produce the result
- **untested** — no non-HID attempt has been made

| Operation | Current implementation | Non-HID path | Status |
|---|---|---|---|
| Click a page element | `doJavaScript` `el.click()` | same | already non-HID |
| Read / fill / scroll | `doJavaScript` | same | already non-HID |
| Screenshot | AX bounds + `screencapture` | same | already non-HID (#23) |
| Switch tab / close window | AppleScript command | same | already non-HID |
| Dismiss a JavaScript dialog | *(no such command yet — #103)* | `AXPress` on its button | **proven** |
| Cancel a native file dialog | *(no such command yet)* | `AXPress` on Cancel (nested inside the sheet; needs a recursive search) | **proven** |
| Open a native file dialog | `upload --native` clicks the file input | click `<input type="file">` | **proven** |
| **Choose a file in that dialog** | `Cmd+Shift+G` → `Cmd+V` → `Return` | none found | **disproven** — see §4.1 |
| **Export a PDF** | `Cmd+P` + dialog navigation (`--allow-hid`) | possibly `print`; untried | **untested** — see §4.2 |

### How this was measured

Each dialog was produced inside a throwaway Safari window opened for the
purpose, measured, dismissed via `AXPress`, and the window closed — the user's
existing windows were never touched. To re-measure:

```bash
make test-reference-edges     # runs when the conditions are already present
```

That harness detects a live dialog rather than creating one, and reports absence
as *skipped* rather than passed. The measurements in the table above were taken
by deliberately creating each condition; see #97 for the procedure.

**This table expires.** It describes one macOS version and one Safari version.
A status of `disproven` may become reachable, and `proven` may stop being true.
Re-measure before relying on a row, and update the date above when you do.

---

## 3. Choosing a path

> **When a non-HID path is proven, delete the HID path.**

Note the precondition. The rule licenses deletion only against a row marked
**proven** — a path that is `untested` has not earned the deletion, and one that
is `disproven` positively forbids it. Deleting an HID path because the rule
"says so", without a proven replacement, removes a working capability and
replaces it with nothing.

### Why delete rather than keep as a fallback

Keeping both is the tempting compromise, and it is worse than either option
alone:

- **Two paths are two behaviours** to maintain, test, and reason about — and one
  of them is already known to be worse.
- **A retained path becomes a fallback, and fallbacks fire silently.** The caller
  believes they took the safe route; the tool quietly took the other one. That
  failure is invisible at the call site and only shows up as a stolen keystroke
  minutes later.
- **HID conflicts with Non-Interference directly.** It moves the cursor, takes
  focus, and races whatever the user is doing. A path that does this is not a
  peer of one that doesn't.
- **`--allow-hid` is a false choice when a proven alternative exists.** The flag
  offers "dangerous" or "unavailable" — and when there is a third option, making
  the user pick between the first two is a design failure, not a safety feature.

### Where the rule does not reach

The rule governs *how* an operation is performed, not *whether* it happens
automatically. A non-HID action can still be surprising — see §1's two
properties. Commands whose effect the user should consciously authorise stay
behind explicit opt-in regardless of which path they use; `setup` (#98) and the
proposed `dialog dismiss` (#103) are both non-HID **and** opt-in, for different
reasons.

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

The likely explanation: that text field is the sidebar's search box. The real
path-entry field belongs to the **nested sheet that `Cmd+Shift+G` creates** —
and that sheet does not exist until the keystroke is sent. The HID here is not
laziness; the UI element being driven has to be summoned by HID first.

This also explains the shape of #67 (`Go to Folder panel did not appear within
10 seconds`): the thing that fails to appear is exactly this nested sheet.

Tracked in **#101**. If a different non-HID route exists — driving the dialog's
file browser (`AXOutline` / `AXBrowser`) to select the target directly, never
needing Go-to-Folder — then the keystrokes can go, and #67's hang family goes
with them structurally.

### 4.2 Exporting a PDF — untested, and testing has side effects

`PdfCommand` requires `--allow-hid` and drives `Cmd+P` plus dialog navigation.

Safari's own scripting definition exposes nine commands, none of which is
`print`, `save`, or `export`. But it inherits the Cocoa Standard Suite via
`xi:include`, and `osacompile -e 'tell application "Safari" to print document 1'`
**compiles** — the verb exists.

What is unknown is whether it can be aimed at a PDF file rather than a printer.
**Testing that has a real side effect**: wrong parameters may send an actual
print job. It needs a deliberate, isolated experiment, not a casual probe during
other work.

Tracked in **#102**, including a second route worth trying: the print sheet is
itself reachable via Accessibility, so `AXPress` on its PDF popup may reach
"Save as PDF" without any keystroke.

---

## 5. Relationship to Foresay P02

This document is an instance of **P02 Multi-Representation** from
[Foresay](https://github.com/kiki830621/foresay) (`kiki830621/foresay` v5.0.0,
private; path below is relative to that repo root —
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
| **Document transitions** | when an intent crosses paths it stays traceable (e.g. `upload` falling back from native to JS DataTransfer) |
| **Debug along the chain** | locating *which path* failed is half the diagnosis — #67 is precisely a failure localised to one path |

### What this repo adds on top of P02

P02 requires naming which representation is meant. It does **not** rank them.

This document adds a **preference order with elimination**: the paths are not
equivalent alternatives to be named and left standing — the worse one is
deleted once the better one is proven. That ordering is a safari-browser rule,
justified by the Non-Interference principle, and should not be attributed to
P02 itself.

---

## See also

- [`openspec/specs/non-interference/spec.md`](../openspec/specs/non-interference/spec.md) — the principle this document expands along the execution-path axis
- **#101** — file selection: no non-HID path found (blocks retiring `upload`'s keystrokes)
- **#102** — PDF export: non-HID feasibility untested
- **#103** — `dialog list` / `dialog dismiss`: proven non-HID, no opt-in command yet
- **#67** — stuck native file dialog; the failure family that lives on the HID path
- **#98** — `setup`: the other command that deliberately raises a system dialog, and why that is not a contradiction
