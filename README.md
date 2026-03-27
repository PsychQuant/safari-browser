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
safari-browser wait --url "dashboard"

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
safari-browser pdf [path]              # export as PDF
safari-browser upload <sel> <file>     # file upload via System Events dialog
```

### Tab Management

```bash
safari-browser tabs [--json]           # list all tabs
safari-browser tab <n>                 # switch to tab
safari-browser tab new                 # new tab
```

### Wait

```bash
safari-browser wait <ms>               # wait milliseconds
safari-browser wait --url <pattern>    # wait for URL match
safari-browser wait --js <expr>        # wait for JS truthy
safari-browser wait --timeout <ms>     # custom timeout (default 30s)
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
make build    # debug build
make install  # release build + install to ~/bin
make clean    # remove build artifacts
```

## License

MIT
