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

## Commands (36)

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
safari-browser scrollintoview <sel>    # scroll into view
safari-browser drag <src> <dst>        # drag and drop
safari-browser highlight <sel>         # red outline (debug)
```

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

### Screenshot, PDF & Upload

```bash
safari-browser screenshot [path]       # window screenshot (default: screenshot.png)
safari-browser screenshot --full path  # full page
safari-browser pdf --allow-hid [path]  # export as PDF (requires --allow-hid)
safari-browser upload <sel> <file>     # native file dialog (default, fast, large files OK)
safari-browser upload --js <sel> <file>  # JS DataTransfer injection (no permissions, slow for large files)
```

`upload` uses native file dialog by default when Accessibility permission is granted (fast, any file size). Without permission, it falls back to JS DataTransfer automatically. Use `--js` to force JS mode. `pdf` always requires `--allow-hid` (no JS alternative).

### Tab Management

```bash
safari-browser tabs [--json]           # list all tabs (front window)
safari-browser tabs --window 2         # list tabs of window 2
safari-browser tab <n>                 # switch to tab
safari-browser tab new                 # new tab
safari-browser tab new --window 2      # new tab in window 2
```

### Multi-window Targeting (#17 #18 #21 #23)

When Safari has more than one window, every subcommand that reads from or
drives a document accepts one of four mutually exclusive global flags:

```bash
safari-browser <cmd> --url <pattern>   # first document whose URL contains pattern
safari-browser <cmd> --window <n>      # current document of the Nth window (1-indexed)
safari-browser <cmd> --tab <n>         # document N (alias for --document)
safari-browser <cmd> --document <n>    # document N in Safari's document collection
```

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
error. `close`, `screenshot`, `pdf`, and `upload --native` also only
accept `--window` because they drive window-scoped primitives
(AppleScript `close current tab of window N`, CG window ID capture,
System Events keystrokes against the frontmost window) — see #23.
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

# Upload split path (#23) — JS targets any document, native is window-only
safari-browser upload --js "input[type=file]" file.mp3 --url plaud
safari-browser upload --native "input[type=file]" file.mp3 --window 2

# Window-scoped operations (#23)
safari-browser close --window 2              # closes window 2's current tab
safari-browser screenshot --window 2 out.png # raises window 2, then captures
safari-browser pdf --window 2 --allow-hid out.pdf
```

`pdf --window N` and `upload --native --window N` briefly **raise
window N to the front** before their respective System Events keystroke
operations. Keystrokes inherently target the front window, so the raise
is part of the operation, not just identification.

`screenshot --window N` (R6) uses the **AXUIElement private SPI**
(`_AXUIElementGetWindow`) to map AS `window N` to a CG window ID
**without raising the window**. This avoids the silent wrong-window
failure modes that bedevil bounds- and title-based matching (see #23
verify R1-R5 for the saga). The trade-off is that `screenshot --window`
now requires Accessibility permission for the CLI's host process
(Terminal.app / iTerm / etc) — first-time use without permission throws
`accessibilityNotGranted` with grant instructions.

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
