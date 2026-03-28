# Changelog

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
