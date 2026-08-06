# safari-browser

macOS native browser automation CLI via Safari + AppleScript.

**Your browser, your session.** Unlike headless Chromium tools, safari-browser controls the Safari you already use — localStorage, cookies, SSO sessions, 2FA tokens all persist. No login scripts, no cookie injection, no auth management.

## Why safari-browser?

| | Headless tools (Playwright, etc.) | safari-browser |
|---|---|---|
| **Login state** | Fresh browser every time | **Permanently logged in** |
| **Bot detection** | Frequently blocked by banks, social media | **Real Safari — undetectable** |
| **2FA / SSO** | Must handle every time | **Session already verified** |
| **User visibility** | Hidden Chromium instance | **Your Safari — watch and intervene anytime** |
| **macOS integration** | None | **Keychain, iCloud cookies, Safari Extensions** |

### When to use

```
Need login? ──── Yes → safari-browser
              └── No → Need headless/CI? ──── Yes → Playwright / agent-browser
                                           └── No → Either works
```

### Use cases

- **Enterprise SaaS** (Notion, Slack, JIRA) — SSO session persists
- **Banking & finance** — banks block headless browsers
- **Social media** (Facebook, Instagram, X) — bot detection immune
- **AI + human collaboration** — user watches AI work, takes over anytime
- **2FA / MFA sites** — already authenticated in Safari
- **Extract API tokens** — `safari-browser js "localStorage.getItem('token')"`

## Install

```bash
git clone https://github.com/PsychQuant/safari-browser.git
cd safari-browser
make install
```

Binary installs to `~/bin/safari-browser`. Ensure `~/bin` is in your `$PATH`.

**Requirements:** macOS 15+, Safari, Swift 6.0+

## Quick Start

```bash
# Navigate
safari-browser open "https://example.com"

# Discover interactive elements
safari-browser snapshot
# @e1  input[type="email"]  #login-email  placeholder="Email"
# @e2  input[type="password"]  placeholder="Password"
# @e3  button  "Sign In"

# Interact using @refs or CSS selectors
safari-browser fill @e1 "user@example.com"
safari-browser fill @e2 "secret"
safari-browser click @e3

# Wait for navigation
safari-browser wait --for-url "dashboard"

# Extract data
safari-browser get text "h1"
TOKEN=$(safari-browser js "localStorage.getItem('token')")
```

## Commands (42)

### Navigation

```bash
safari-browser open <url> [--new-tab] [--new-window]
safari-browser back / forward / reload / close
```

### Element Discovery (Snapshot + @ref)

```bash
safari-browser snapshot                # scan interactive elements → @e1, @e2...
safari-browser snapshot -c             # compact (exclude hidden)
safari-browser snapshot -d 3           # limit DOM depth
safari-browser snapshot -s "form"      # scope to selector
safari-browser snapshot --json         # JSON array output
safari-browser snapshot --page         # full page state (accessibility tree + metadata)
safari-browser snapshot --page --json  # full page state as JSON
safari-browser snapshot --page -s "main"  # scoped page scan
```

All selector-accepting commands support `@eN` refs.

### Element Interaction

```bash
safari-browser click <sel>             # click
safari-browser dblclick <sel>          # double-click
safari-browser fill <sel> <text>       # clear + fill (fires input/change events)
safari-browser type <sel> <text>       # append text
safari-browser select <sel> <value>    # dropdown
safari-browser hover <sel>             # hover
safari-browser focus <sel>             # focus
safari-browser check / uncheck <sel>   # checkbox
safari-browser scroll <dir> [px]       # up/down/left/right (default 500px)
safari-browser scroll <dir> [px] --selector <sel>   # scroll a nested container
safari-browser scrollintoview <sel>    # scroll into view
safari-browser drag <src> <dst>        # drag and drop
safari-browser highlight <sel>         # red outline (debug)
```

`--selector` scrolls a nested scrollable container (message lists, feeds)
rather than the page — `window.scrollBy` does nothing to those, and the page
around them often has nothing to scroll at all. The command reports the two
outcomes that would otherwise be silent no-ops: an element with no overflow
fails with `Element matches but is not scrollable` (usually the selector
matched a wrapper rather than the child carrying the overflow, so the error
includes a one-liner that lists the page's real scroll containers), and a
container already at the end of its range prints a `did not move` note to
stderr — not an error, but a loop that cannot see it never terminates.

### Keyboard

```bash
safari-browser press Enter
safari-browser press Tab / Escape
safari-browser press Control+a         # modifier combos
safari-browser press Shift+Tab
```

### Find Elements

```bash
safari-browser find text "Submit" click
safari-browser find role "button" click
safari-browser find label "Email" fill "user@example.com"
safari-browser find placeholder "Search" fill "query"
```

### Page & Element Info

```bash
safari-browser get url / title / source
safari-browser get text [selector]     # full page or element
safari-browser get html <sel>          # innerHTML
safari-browser get value <sel>         # input value
safari-browser get attr <sel> <name>   # attribute
safari-browser get count <sel>         # element count
safari-browser get box <sel>           # bounding box (JSON)
```

### State Checks

```bash
safari-browser is visible <sel>        # true/false
safari-browser is exists <sel>
safari-browser is enabled <sel>
safari-browser is checked <sel>
```

### JavaScript

```bash
safari-browser js "<code>"             # execute JS, print result
safari-browser js --file script.js     # from file
safari-browser js --large "<code>"     # chunked read for large output (>1MB)
safari-browser js --output file "<code>"  # write result to file
```

`js` is eval-free (#76): it works on strict-CSP pages (`script-src` without
`'unsafe-eval'` — facebook.com, claude.ai, most modern sites). A single
expression prints its value (`js "1+1"` → `2`). A multi-statement script runs
as a function body — use `return` for a value:

```bash
safari-browser js "var a = 2; return a + 3;"   # → 5
```

Breaking change vs pre-#76: multi-statement scripts no longer yield the last
expression's value implicitly (old page-context `eval()` semantics); without
`return` the result is `undefined`. Code that itself calls `eval()`/`new
Function()` still fails on strict-CSP pages — the error includes a hint.

Two edge notes (#76 verify round):

- Grammatically ambiguous inputs now parse as expressions: `js "{}"` yields
  `[object Object]` (eval treated it as an empty block → `undefined`), and
  `js "function f(){}"` / `js "class A {}"` yield the source text instead of
  declaring anything.

**The `exec` script `js` step and the CLI `js` command agree** — a snippet
moves between them unchanged (#80, measured):

| Snippet | CLI `js` | `exec` `js` step |
|---|---|---|
| `1 + 1` | `2` | `2` |
| `document.title` | the title | the title |
| `{}` | `[object Object]` | `[object Object]` |
| `var a = 2; a + 3` | `undefined` | `undefined` |
| `var a = 2; return a + 3` | `5` | `5` |

They arrive there by different routes — the CLI wraps your code so it can
carry results, errors and >1MB payloads across an AppleScript boundary that
only returns strings, while an `exec` step hands the code to Safari's
`do JavaScript` unwrapped — but Safari evaluates a script as a *function body*
too, so both end up needing `return` for a multi-statement value.

`#80` was filed expecting `exec` to keep completion-value semantics
(`var a = 2; a + 3` → `5`). It does not, and the table above is the measured
behavior on both surfaces.

### Screenshot, PDF & Upload

```bash
safari-browser screenshot [path]       # window screenshot (default: screenshot.png)
safari-browser screenshot --full path  # full page
safari-browser pdf --allow-hid [path]  # export as PDF (requires --allow-hid)
safari-browser upload <sel> <file>     # native file dialog (default, fast, large files OK)
safari-browser upload --js <sel> <file>  # JS DataTransfer injection (no permissions, slow for large files)
```

`upload` uses native file dialog by default when Accessibility permission is granted (fast, any file size). Without permission, it falls back to JS DataTransfer automatically. Use `--js` to force JS mode. `pdf` always requires `--allow-hid` (no JS alternative).

Which commands synthesise keyboard/mouse events, which reach Safari another way, and the rule for when a keystroke path may be deleted: [`docs/operation-paths.md`](docs/operation-paths.md). Note `--allow-hid` on `pdf` gates the *save-destination* keystrokes, not the export itself — that part is already keystroke-free.

### Tab Management

```bash
safari-browser tabs [--json]           # list all tabs (front window)
safari-browser tabs --window 2         # list tabs of window 2
safari-browser tab <n>                 # switch to tab
safari-browser tab new                 # new tab
safari-browser tab new --window 2      # new tab in window 2
```

### Blocking Dialogs

```bash
safari-browser dialog list                     # show the dialog's text and buttons
safari-browser dialog dismiss --button "取消"   # press the button you named
```

A JavaScript `alert` / `confirm` blocks `js`, `get text` and anything else that
runs script in that document — and it may be on a Space you are not looking at,
so `dialog list` is often the fastest way to find out why a command hung.

Dismissal deliberately makes you name the button, and there is no
press-the-default shortcut: clicking an unread dialog can confirm an action you
never saw. The dialog's full text is printed before the press so your log records
what was dismissed. A title that matches nothing presses nothing and lists the
real buttons instead — they are localized.

The press uses the Accessibility action, not synthetic input, so the cursor never
moves and `--allow-hid` is neither needed nor accepted. It does need the
Accessibility grant (see below), and it does change state, which is why it is a
command you type rather than something that happens automatically.

### Permissions

```bash
safari-browser setup                  # show status, then request what is missing
safari-browser setup --check          # status only, never raises a dialog (exit 1 if incomplete)
safari-browser setup --open-settings  # also open the relevant System Settings panes
```

Two macOS permissions gate part of the CLI:

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | window resolution for `screenshot` / `pdf` / `upload --native`, blocked-dialog detection | those paths refuse; front-window resolution falls back to a heuristic and says so |
| **Screen Recording** | the pixel capture inside `screenshot` | `screenshot` refuses with guidance |

`setup` is the **only** command that raises a permission dialog. Every other
command detects and refuses with guidance instead, because a background
automation run must never pop an alert — a dialog you asked for by typing
`setup` is not an interruption. Nothing else changed about that.

Three things regularly look like bugs and are not:

- A grant applies at **process start**, so the status printed immediately after
  granting still says NOT granted. Re-run to confirm.
- The grant attaches to whatever macOS holds responsible for the process, which
  for a shell-launched CLI is often the terminal app rather than the binary.
  `setup` prints the binary path so you can check both names in Settings.
- macOS offers the Screen Recording prompt **once per app, ever**. If it never
  appears, use `--open-settings` and add the binary with `+`.

`make install` re-signs the copied binary, because TCC keys a grant to the code
signature — an unsigned copy is a different subject with no permissions.

### Multi-window Targeting (#17 #18 #21 #23 #79)

When Safari has more than one window, every subcommand that reads from or
drives a document accepts one of four mutually exclusive global flags:

```bash
safari-browser <cmd> --url <substring>  # tab whose URL CONTAINS this text (see below)
safari-browser <cmd> --window <n>       # current document of the Nth window (1-indexed)
safari-browser <cmd> --window <n> --tab-in-window <m>   # window N's Mth tab — "wN.tM"
safari-browser <cmd> --tab <n>          # document N (alias for --document)
safari-browser <cmd> --document <n>     # document N in Safari's document collection
safari-browser <cmd> --profile <name>   # restrict to windows of named Safari profile (#47)
```

**`--url` is a substring match against the URL** — not the whole URL, and not
the page title. `--url plaud` matches `https://app.plaud.ai/…`; `--url "My
Notes"` matches nothing even when that is exactly what the tab is called.
Stricter variants: `--url-exact`, `--url-endswith`, `--url-regex`.

A miss therefore reports `No Safari document matches "…"` — the flag ran and
found nothing. That is a different failure from an unsupported flag, which
reports `Unknown option`. Reading the first as the second sends you looking
for a missing feature instead of a better substring (#71); the error now says
which one happened and lists each tab's `window N tab M` coordinates so you
can retarget positionally (#72).

**To target "window 1, tab 3"** use `--window 1 --tab-in-window 3`. Run
`safari-browser documents` first — its `wN.tM` column is exactly these two
numbers.

**Identity-anchored `--url` / `--document` resolution (#79)**: a `--url` or
`--document` match resolves to the tab's *identity* (`tab T of window id W`,
using Safari's stable window id), not its z-order position — so
multi-round-trip commands (`js`, chunked reads) keep hitting the same tab
even if you click other Safari windows mid-command. Every round-trip
re-verifies the tab's URL (case-sensitively) in the same AppleScript; on a
miss (window closed, tab moved, or navigated to a non-matching URL) the
command re-resolves once **within the same window and profile** and
otherwise fails closed with `targetTabChanged` — never a silent wrong-tab
dispatch. Explicit `--window N` / `--tab-in-window M` stay positional
**by design**: those flags mean "whatever sits at this position right now".

Known boundaries: a same-tab navigation to a URL that *still matches* your
pattern resets the page's JS context between round-trips — the guard cannot
distinguish it (tracked in #82 with the navigation family); on strict
same-URL duplicates within one window, a re-resolve after a tab shift may
follow the duplicate (Safari tabs have no stable id — window identity is
the strongest available anchor).

`--profile` (#47) is orthogonal — combine with any other lock flag to
disambiguate same-URL tabs across Safari profiles. **Detection mechanism**:
Safari prepends the active profile name to each window title with em-dash
separator (`<profile> — <page-title>`). AppleScript has no `current profile`
property (verified Safari 18), so this is the only reliable mechanism.
Currently honored by `js`, `get url / title`, `screenshot`, `documents`;
other commands accept the flag but the filter is a no-op (broader rollout
tracked).

**Stderr warning for unhonored commands (#54)**: when `--profile` is passed
to a command that doesn't yet enforce the filter, `safari-browser` emits a
single stderr line before execution to prevent silent wrong-profile
dispatch:

```
$ safari-browser click --profile work "#delete"
warning: --profile 'work' is parsed but not yet enforced for 'click'. Tracked in #51.
  → Falling back: all profiles considered.
```

The warning goes to stderr only — stdout (e.g. `get text` body content) is
unaffected. To filter from a pipeline, redirect stderr: `safari-browser
click --profile work "#x" 2>/dev/null`. Per `#51` plumb-rollout, individual
commands graduate to honored over time; the warning helper exists only for
the transitional period.

**Exec sub-step double-warning (#62, by design)**: a pathological invocation
that passes `--profile` to BOTH the exec parent and a sub-step with its own
`--profile` emits **two** warnings — one for the parent `exec`, one for the
child command — e.g.:

```
safari-browser exec --profile A --script '[{"cmd":"click","args":["x","--profile","B"]}]'
# warning: --profile 'A' is parsed but not yet enforced for 'exec'. ...
# warning: --profile 'B' is parsed but not yet enforced for 'click'. ...
```

This is intentional: each unhonored command that receives a `--profile` warns,
and an explicit sub-step `--profile` is a distinct override (it rides as its own
target per `#60`), so the dual warning is *more* informative, not a bug. A
sub-step with no `--profile` inherits the parent's profile silently (one warning
at the parent only).

Without any flag, commands default to `document 1` — equivalent to
`current tab of front window` in single-window usage, so existing scripts
keep working unchanged. Read-only queries (`get url`, `get title`,
`get source`, `js`, etc.) use document-scoped access so they still return
even when the front window has a modal file dialog sheet open (the
classic `#21` hang).

```bash
# Discover which documents are currently open
safari-browser documents                # [1] https://… — title (per line)
safari-browser documents --json         # machine-readable [{index, url, title}]

# Target by URL substring (most common)
safari-browser get url --url plaud      # https://web.plaud.ai/
safari-browser click "button.upload" --url plaud
safari-browser js "document.title" --url plaud

# Target by window or document index
safari-browser get title --window 2
safari-browser fill "input#email" "user@example.com" --document 3
```

`tabs`, `tab <n>`, `tab new`, `open --new-tab`, and `open --new-window`
only accept `--window` because they are window-level UI operations;
supplying `--url`, `--tab`, or `--document` is rejected with a usage
error.

`close`, `screenshot`, `pdf`, and `upload --native` **accept the full
targeting surface** (`--url`, `--window`, `--tab`, `--document`) via
the native-path resolver introduced in #26 — the resolver maps every
targeting flag to a concrete `(windowIndex, tabIndexInWindow)` pair
before dispatching the keystroke / AX operation. Multi-match `--url`
patterns fail closed with `ambiguousWindowMatch` listing every
candidate, rather than silently picking first-match — deterministic
automation behavior.

URL matching is case-sensitive (AppleScript's native behavior).
Substring match — no regex — so `--url plaud` matches any URL containing
"plaud". If no document matches, you get a `documentNotFound` error
whose description lists every currently open document so you can fix
the pattern without running another command.

```bash
# Storage targeting (#23) — critical for per-origin tokens
safari-browser storage local get token --url plaud   # Plaud's token
safari-browser storage local get token --url oauth   # OAuth provider's token

# Wait targeting (#23)
safari-browser wait --for-url "/dashboard" --url plaud

# Snapshot targeting (#23)
safari-browser snapshot --url plaud
safari-browser snapshot --page --document 2

# Upload split path (#23 → #26) — both paths accept full targeting
safari-browser upload --js "input[type=file]" file.mp3 --url plaud
safari-browser upload --native "input[type=file]" file.mp3 --url plaud  # #26
safari-browser upload --native "input[type=file]" file.mp3 --window 2

# Window-scoped operations (#23 → #26)
safari-browser close --url plaud             # closes the plaud tab
safari-browser screenshot --url plaud out.png  # captures plaud's window
safari-browser pdf --url docs --allow-hid out.pdf
safari-browser close --window 2              # closes window 2's current tab
safari-browser screenshot --window 2 out.png # captures window 2
safari-browser pdf --window 2 --allow-hid out.pdf
```

`pdf`, `upload --native`, and `close` briefly **raise the resolved
window to the front** before their respective System Events keystroke
operations. Keystrokes inherently target the front window, so the raise
is part of the operation, not just identification. When the resolver
identifies a background tab within that window, these commands also
briefly switch to that tab (`set current tab of window N to tab T`)
before dispatching — documented as a passively interfering side effect
transitively authorized by `--native` / `--allow-hid` in the
non-interference spec.

`screenshot` deliberately does **not** tab-switch — it observes without
interfering. A `--url` that resolves to a background tab captures the
window's currently-visible content (which may differ from the targeted
tab). Users who need DOM-level content of a background tab should
switch tabs first, or use document-scoped commands (`snapshot --url`,
`get text --url`, `get source --url`) that read via JavaScript without
touching window focus.

`screenshot` (R7) uses the **AXUIElement private SPI**
(`_AXUIElementGetWindow`) to map AppleScript window indices to CG
window IDs **without raising the window**. Both `screenshot --window N`
and default `screenshot` (no flag) use AX when Accessibility is
granted — eliminating the silent wrong-window failure modes that
bedevil bounds- and title-based matching (see #23 verify R1-R6 for
the saga). Without Accessibility, `screenshot` (no flag) falls back
to the legacy CG name-match resolver; `screenshot --window N` throws
`accessibilityNotGranted` with grant instructions.

When `--full` is combined with AX-resolved targeting, window bounds
read/write also go through AX (`kAXPositionAttribute` /
`kAXSizeAttribute`) on the same element that was resolved for CG
capture — eliminating the R6 cross-API mismatch where resize could
hit a different window than the capture.

Ambiguity is fail-closed: if AX bounds matching can't uniquely
identify the requested window, the command throws `noSafariWindow`
instead of silently guessing. Previous rounds silently fell back to
"guess by AS-index = AX-index" — R7 removes that path entirely.

```bash
# Grant once via System Settings → Privacy & Security → Accessibility,
# then `screenshot --window N` works for all Safari windows including
# off-Space, unminimized, and arbitrarily-sized windows — no z-order
# disruption, no race conditions.
safari-browser screenshot --window 2 background.png
```

If you don't want to grant Accessibility, use document-scoped commands
that don't need a CG window ID: `snapshot --url <pattern>`, `get text
--url <pattern>`, `get source --url <pattern>`, etc. — these read DOM
content via JavaScript without crossing the window-ID boundary.

`screenshot` (no `--window` flag) still works without Accessibility —
it captures the current front Safari window via legacy CG name match.

### Wait

```bash
safari-browser wait <ms>                 # wait milliseconds
safari-browser wait --for-url <pattern>  # wait for URL match
safari-browser wait --js <expr>          # wait for JS truthy
safari-browser wait --timeout <ms>       # custom timeout (default 30s)

# Multi-window targeting (#23): wait polls the targeted document, not
# the front window, so you can wait for a Plaud redirect while some
# other window has focus.
safari-browser wait --for-url "/dashboard" --url plaud
safari-browser wait --js "window.loaded" --document 2
```

### Storage

```bash
safari-browser cookies get [name]      # get cookies
safari-browser cookies get --json      # as JSON object
safari-browser cookies set <n> <v>     # set cookie
safari-browser cookies clear           # clear all
safari-browser storage local get/set/remove/clear <key> [value]
safari-browser storage session get/set/remove/clear <key> [value]
```

### Settings

```bash
safari-browser set media dark          # force dark mode
safari-browser set media light         # force light mode
```

### Debug

```bash
safari-browser console --start         # capture log/warn/error/info/debug
safari-browser console                 # read ([warn], [error] prefixed)
safari-browser console --clear
safari-browser errors --start          # capture JS errors
safari-browser errors
safari-browser mouse move <x> <y>     # mouse events
safari-browser mouse down / up / wheel <dy>
```

### Daemon (opt-in, Phase 1)

Long-running daemon that keeps AppleScript handles pre-compiled in memory, shaving `osascript`'s ~3s spawn cost off each repeat invocation. **Opt-in** — default CLI stays stateless.

```bash
safari-browser daemon start            # fork detached, listen on Unix socket
safari-browser daemon status           # pid, uptime, request count, last activity
safari-browser daemon logs             # tail daemon log
safari-browser daemon stop             # shut down + clean socket/pid

# Route a single command through the daemon
safari-browser documents --daemon

# Or set once, every future command auto-routes if socket is live
export SAFARI_BROWSER_DAEMON=1

# Namespace (two agents can run independent daemons)
SAFARI_BROWSER_NAME=alpha safari-browser daemon start
SAFARI_BROWSER_NAME=beta  safari-browser daemon start
```

**Phase 1 command coverage** (routed through daemon when enabled):
`snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`.

**NOT covered** (fall through to stateless path even with daemon on):
`screenshot`, `pdf`, `upload --native`, `upload --allow-hid`.

If the daemon is missing, crashed, version-mismatched, or unresponsive (15s), commands **silently fall back** to the stateless path with a single `[daemon fallback: <reason>]` stderr line. Idle >10 minutes → daemon auto-exits. See `openspec/specs/persistent-daemon/spec.md` for full semantics.

### Exec scripts (multi-step automation)

`safari-browser exec` runs a JSON array of step objects in one invocation with shared target resolution, variable capture (`$name`), and minimal conditional flow (`if:` with `contains` / `equals` / `exists`). Designed for agents and CI that need deterministic multi-step automation without bash plumbing.

```bash
# Heredoc style
safari-browser exec --url plaud <<'JSON'
[
  {"cmd": "get url", "var": "u"},
  {"cmd": "js", "args": ["1+1"], "if": "$u contains \"plaud\""},
  {"cmd": "click", "args": ["button.upload"]}
]
JSON

# From file
safari-browser exec --script /tmp/login.json --url plaud
```

Output: single JSON array on stdout, one entry per executed/skipped step (`{"step": N, "status": "ok"|"error"|"skipped", "value": ..., "var": "..."?}`). Default cap of 1000 steps (override with `--max-steps`). v1 dispatches via subprocess to the same binary, so daemon opt-in still amortizes per-step cost. `screenshot`, `pdf`, `upload` fall through with `unsupportedInExec`. See `openspec/specs/script-exec/spec.md`.

### Tab ownership marker (opt-in)

`--mark-tab` wraps the target tab's title with an invisible zero-width marker so sibling `safari-browser` invocations can detect "I'm working here" via `tab is-marked`. **Advisory, not a lock.**

```bash
# Persist marker across invocations
safari-browser click button.upload --url plaud --mark-tab-persist

# Sibling process probes ownership (exit 0 = marked, 1 = unmarked, 2 = error)
safari-browser tab is-marked --url plaud && echo "tab is busy"

# Explicit cleanup if needed
safari-browser tab unmark --url plaud
```

Marker is hardcoded zero-width characters (no caller-supplied content — security side-channel concern). Default OFF; opt-in only. Page-driven title changes during the operation surface as a stderr warning, no force-restore. v1 wires `ClickCommand` as the reference integration; broader command rollout is v2. See `openspec/specs/tab-ownership-marker/spec.md`.

## Comparison with agent-browser

| Feature | agent-browser | safari-browser |
|---------|--------------|----------------|
| Login state | Fresh each time | **Permanent** |
| User visible | Hidden Chromium | **User's Safari** |
| Bot detection | Detectable | **Real browser** |
| 2FA / SSO | Handle each time | **Already verified** |
| macOS integration | None | **Keychain, iCloud, Extensions** |
| Engine | Playwright / Chromium | Safari + AppleScript |
| Headless | Yes | No |
| Cross-platform | Linux / Windows / macOS | macOS only |
| Network interception | Yes | No |
| Element discovery | CDP accessibility tree | JS DOM scan (snapshot) |
| Parallel sessions | Isolated instances | Shared Safari (multi-tab) |

## Migrating from v2.4 to v2.5 (tab-targeting-v2)

Four breaking changes. Each has a simple opt-out for scripts that cannot migrate immediately.

| Old behavior (v2.4) | New behavior (v2.5) | Migration |
|---|---|---|
| `open <url>` navigates the front window's current tab via JavaScript, regardless of whether that URL is already open elsewhere. | `open <url>` focuses the existing tab if any tab's URL exactly matches; otherwise opens a new tab. Cross-window focus uses the spatial interaction gradient (`open --focus-existing` behavior). | Need the navigate-front-tab semantics? Use `safari-browser open --replace-tab <url>`. |
| `js --url plaud "..."` with two matching tabs silently picks the first. | `js --url plaud "..."` with two matching tabs exits with `ambiguousWindowMatch` listing every candidate. | Need silent first-match? Add `--first-match` (emits a stderr warning enumerating all matches and the chosen one). Or target a specific tab: `--window M --tab-in-window N`. |
| `--tab N` aliases `--document N` (global document index). | `--tab N` still works but emits a stderr deprecation warning. Will be removed in v3.0. | Rename to `--document N` for identical semantics, or rewrite as `--window M --tab-in-window N` to address a specific tab within a window. |
| `safari-browser documents` prints one line per Safari window (each window's front tab). | Prints one line per tab across all windows. Format: `[global] <current-marker> w<window>.t<tab>  <url> — <title>`. `--json` adds `window` / `tab_in_window` / `is_current` fields. | Shell parsers counting document lines as "number of windows" must switch to grouping by the `w{N}` prefix or use `--json`. The `--document N` semantic is unchanged — it still targets the Nth tab in enumeration order. |

New flags:

- **`--tab-in-window N`** — requires `--window M`. Targets the Nth tab within the Mth window. Escape hatch for duplicate-URL tabs.
- **`--first-match`** — accepts first `--url` match when multiple tabs match (paired with stderr warning).
- **`--replace-tab`** — on `open`, restores v2.4 navigate-front-tab behavior. Mutually exclusive with `--new-tab` / `--new-window`.

Design rationale lives in `openspec/changes/archive/*-tab-targeting-v2/` after archive (or `openspec/changes/tab-targeting-v2/` while in-flight). The new `human-emulation` principle is documented alongside `non-interference` in `CLAUDE.md`.

## Development

```bash
make build      # debug build
make install    # release build + install to ~/bin
make test       # run unit tests (24 tests, no Safari needed)
make test-e2e   # run E2E tests (9 tests, requires Safari)
make clean      # remove build artifacts
```

## License

MIT
