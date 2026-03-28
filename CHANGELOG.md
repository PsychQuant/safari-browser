# Changelog

## 2026-03-28 (round 6)

### Codex Round 5 Fixes
- **P2: cookie regex escape** — Escape special regex characters in cookie name before matching
- **P2: checkbox click activation** — Use `.click()` instead of toggling `.checked` property so change events fire correctly
- **P2: press help accuracy** — Fix help text for press command to reflect actual supported keys

### Codex Round 4 Fix
- **P2: press Enter/Tab regression** — Restrict Enter form-submit to input controls only; filter tabbable elements to visible focusable elements

## 2026-03-28 (round 4)

### Codex Round 3 Fixes
- **P2: runAppleScript trailing newline** — Only strip the single trailing newline added by osascript, preserving content newlines in output
- **P2: console/errors --clear flag** — Use separate `installed` flag so `--start` works correctly after `--clear`
- **P2: get html chunked fallback** — `get html` now falls back to chunked read for large innerHTML content
- **P2: press key defaults** — `press Enter` simulates form submit, `press Tab` focuses next element, `press Escape` blurs — sensible defaults without requiring explicit JS

## 2026-03-28 (round 3)

### Codex Round 2 Fixes
- **P1: snapshot fixed-position** — Include `position: fixed/sticky` elements that have `offsetParent === null` but are visible
- **P1: upload E2BIG** — Transfer base64 file data in 200KB chunks instead of inlining entire file in osascript argument
- **P2: console circular object** — Catch `JSON.stringify` errors on cyclic objects, fall back to `String(a)`
- **P2: errors handler preservation** — Chain existing `window.onerror` instead of replacing it
- **P2: select invalid option** — Report error when option value doesn't match any `<option>` in the `<select>`
- **P2: pdf locale** — Added comment documenting English-only menu label limitation

## 2026-03-28 (late)

### Codex Review Fixes
- **HIGH: Path injection in keystroke** — PDF and upload HID fallback now escape file paths with `escapedForAppleScript` before embedding in `keystroke`
- **MEDIUM: js --file multi-line scripts** — `js` command now uses eval wrapping + `jsStringLiteral` to support multi-statement scripts, not just single expressions
- **MEDIUM: snapshot silent truncation** — Detects truncated JSON and retries with chunked read; emits warning if parsing still fails
- **MEDIUM: wait negative crash** — Rejects negative milliseconds with validation error instead of UInt64 overflow crash
- **MEDIUM: screenshot --full restore** — Always restores window bounds and scroll position, even if screencapture fails

## 2026-03-28

### Security Fixes
- **#3 String injection** — `escapedForAppleScript` and `escapedForJS` now handle newlines, null bytes, and unicode line separators. All URLs escaped before embedding in AppleScript.
- **#2 HID opt-in** — `upload` defaults to JS DataTransfer file injection (no keyboard control). `pdf` requires `--allow-hid`. Both warn on stderr when HID is active.

### Bug Fixes
- **#4 Pipe deadlock** — Read pipe data before `waitUntilExit()` in both `runShell` and `runAppleScript`, preventing deadlock when output exceeds 64KB.
- **#5 JS double execution** — JS command no longer re-executes user code on empty result. Uses sentinel (store result + check length) to detect truncation vs genuinely empty return.
- **#1 Large JS output** — Added `doJavaScriptLarge()` chunked read (256KB chunks). `js --large` and `js --output <file>` flags. `get text` falls back to chunked read on large pages.
- **codesign fix** — `make install` now re-signs binary to prevent macOS Sequoia SIGKILL on adhoc linker-signed binaries.

### Features
- **snapshot** — Element discovery with `@ref` support. `snapshot -c` (compact), `-d` (depth), `-s` (scope), `--json`.
- **parity with agent-browser** — pdf, drag, set media dark/light, tabs --json, cookies get --json, console multi-level capture (log/warn/error/info/debug).
- **convenience commands** — click, fill, type, select, hover, scroll, focus, check/uncheck, dblclick, press, find.
- **advanced features** — screenshot, upload, scrollintoview, highlight, cookies, storage, console, errors, mouse, is visible/exists/enabled/checked, get box/html/value/attr/count.
- **Cauchy delay pattern** — Human-like random delays for anti-bot evasion documented in plugin SKILL.md.

### Infrastructure
- **Plugin** — `safari-browser@psychquant-claude-plugins` v1.2.2 with SKILL.md, SessionStart hook.
- **Tests** — 24 unit tests + 10 E2E tests (shell script).
- **plaud-transcriber migration** — All 15 files migrated from agent-browser to safari-browser.
