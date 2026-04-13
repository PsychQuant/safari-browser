# Changelog

## Unreleased

### Breaking Changes
- **#23: `wait --url <pattern>` renamed to `wait --for-url <pattern>`** — The old `--url` flag on `wait` collided with `TargetOptions.url` (which now means "target the document whose URL contains this substring" across the CLI). Scripts that used the previous syntax must update to `safari-browser wait --for-url "<pattern>"`. The new `--url` on `wait` is a targeting flag inherited from `TargetOptions` — `wait --for-url "/dashboard" --url plaud` polls the URL of the Plaud document instead of the front window. Milliseconds and `--js` forms are unchanged.

### Bug Fixes
- **#19: Wall-clock timeout for osascript / shell subprocesses** — `runShell` and `runAppleScript` used `process.waitUntilExit()` with no timeout, so a stuck osascript (blocked on Safari's Apple Event dispatcher or unresponsive System Events) would hang the whole CLI until `kill -9`. New `runProcessWithTimeout` helper wraps `Process` with a `Task.detached` watchdog that sends SIGTERM, waits 1s, then SIGKILLs; surfaces `SafariBrowserError.processTimedOut(command:seconds:)` on timeout. Default 30s; `upload` uses 60s to accommodate its internal `maxWait to 10` waits.
- **#19 F1 / R2-F1': Bound `--timeout` to a safe finite range** — The first follow-up only rejected `NaN`, `±infinity`, and non-positive values, but `Double.greatestFiniteMagnitude` (and any value like `1e300`) slipped through and still trapped inside `UInt64(timeout * 1e9)`. The guard now enforces `0.001 ≤ timeout ≤ 86_400` in both `UploadCommand.validate()` and `runProcessWithTimeout`, so no reachable input can overflow the nanosecond conversion or round to zero nanoseconds. `SafariBrowserError.invalidTimeout(Double)` surfaces the violation with a clear message.
- **#19 F2 / R2-F2': Double-check `terminationStatus` when reporting a timeout** — The first follow-up latched `didTimeout` before `process.terminate()`, which opened a μs-wide race: if the child exited naturally between the watchdog's `isRunning` check and the SIGTERM, `processTimedOut` was raised despite `terminationStatus == 0`. The main thread now requires both `didTimeout.value == true` *and* `terminationStatus != 0` before classifying a run as a timeout; clean natural exits fall through to the normal success path.
- **#19 F2: Distinguish watchdog kill from external signals** — Previously any `.uncaughtSignal` termination (Ctrl+C propagation, OOM killer, osascript crash) was misreported as `processTimedOut`. The watchdog now flips a `TimeoutFlag` (NSLock-backed) before calling `terminate()`, and the main path only raises `processTimedOut` when that flag is set. Other signal sources fall through to `appleScriptFailed`.
- **#19 F5/F8: Error-message polish** — `processTimedOut` uses `ceil` so sub-second timeouts don't render as "0 seconds", and now includes a troubleshooting hint pointing at Console.app for System Events / Apple Event dispatcher issues.
- **#22: E2E tests are opt-in via `RUN_E2E=1`** — Previously plain `swift test` ran the `E2ETests` suite, whose `setUp` activates Safari and navigates its front window to a fixture page, stealing focus from whatever the user was doing. The suite is now skipped by default and only runs when `RUN_E2E=1` is set. `SKIP_E2E` remains as a redundant opt-out. Brings the test suite in line with the non-interference principle in `openspec/specs/non-interference/spec.md`.
- **#20: Probe System Events before sending keystrokes** — `upload --native` and the PDF export dialog now run a 2-second `probeSystemEvents()` (wrapped inside `runShell(timeout:)` from #19) before touching the keyboard. If the probe is slow (>500 ms) a `⏳ Waiting for System Events...` line is printed to stderr so users never see a silent hang. If the probe fails the bridge prints a loud warning — including the fact that a restart will interrupt other System Events automation (Keyboard Maestro, Alfred, Shortcuts, etc.) — then attempts a best-effort `restartSystemEvents()` (`killall "System Events"` + 500 ms pause for launchd to reap the PID + re-probe; launchd relaunches the process on the subsequent Apple Event). Any remaining failure surfaces as `SafariBrowserError.systemEventsNotResponding(underlying:)`, whose description calls out the user-visible commands (`upload --native`, `pdf`), the paste-able recovery command, and the non-interference warning. `probeSystemEvents(script:timeout:)` accepts an optional `executable:` parameter so tests can exercise the `/nonexistent` binary path. `SystemEventsProbeTests` now `XCTSkipUnless` `/usr/bin/osascript` is executable so sandboxed CI runners don't block on unavailable tools.

### Features
- **#23: Deferred commands wired through multi-document targeting** — Completes the tech-debt backlog from the `multi-document-targeting` change (Phase 8.4 deferrals). `storage local get/set/remove/clear`, `storage session get/set/remove/clear`, `snapshot` (both interactive and `--page`), `wait --for-url / --js`, and `upload --js` now accept the full `TargetOptions` (`--url`, `--window`, `--tab`, `--document`) and route the underlying `doJavaScript` / `getCurrentURL` calls to the requested document. Multi-window users can finally run `safari-browser storage local get token --url plaud` and get Plaud's per-origin token instead of silently reading from `document 1` (the Devil's Advocate Round 1 finding against #17). `close`, `screenshot`, `pdf`, and `upload --native` expose a new `WindowOnlyTargetOptions` (`--window <n>` only) — their underlying primitives (`close current tab of window N`, CG window ID capture, System Events keystrokes) are inherently window-scoped and parse-time reject `--url` / `--tab` / `--document`. `UploadCommand` also gains split-path validation: `--js` accepts any target, `--native` / `--allow-hid` only `--window`, and the smart default routes to `--js` automatically when the user supplies a document-level target. Internally `SafariBridge.closeCurrentTab(window:)` and `SafariBridge.getWindowID(window:)` accept an optional window index (nil = legacy front-window behavior). `ScreenshotCommand --full` threads the same window index through its dimensions read, bounds save/restore, and CG capture so every moving part stays in sync; `PdfCommand` and `UploadCommand --native` raise the target window via `set index of window N to 1` before activating Safari so keystrokes land on the correct window.
- **#19: `upload --timeout <seconds>`** — Override the native file dialog subprocess timeout (default 60s) for slow machines or large directories. Help text now explains why the default is 60s (three stacked `maxWait to 10` loops inside the combined AppleScript).
- **#17 / #18 / #21: Multi-document targeting (in progress via Spectra `multi-document-targeting` change)** — Introduces a new `SafariBridge.TargetDocument` enum with four cases (`frontWindow`, `windowIndex(Int)`, `urlContains(String)`, `documentIndex(Int)`) and a `resolveDocumentReference(_:)` helper that generates AppleScript document references safe to interpolate into any `tell application "Safari"` block. A new global `TargetOptions` (`@OptionGroup`) plumbs `--url <pattern>` / `--window <n>` / `--tab <n>` / `--document <n>` flags through 25+ subcommands — `get url/title/text/source/html/value/attr/count/box`, `open`, `js`, `click`, `fill`, `type`, `select`, `hover`, `scroll`, `press`, `focus`, `dblclick`, `drag`, `scroll-into-view`, `find`, `check`, `uncheck`, `tabs`, `tab`, `is (visible/exists/enabled/checked)`, `back`, `forward`, `reload`, `highlight`, `cookies (get/set/clear)`, `console`, `errors`, `set media`, and `mouse (move/down/up/wheel)`. The flags are mutually exclusive; `tabs`/`tab`/`open --new-tab`/`open --new-window` reject document-level flags because those commands are window-scoped. Read-only page-info getters (`URL`, `name`, `text`, `source`) and `doJavaScript` now use a document-scoped AppleScript reference (`document N` or `first document whose URL contains …`) instead of `current tab of front window`, so queries bypass any modal file dialog sheet blocking the front window (#21). Single-window usage is byte-for-byte unchanged — `.frontWindow` resolves to `document 1`, which equals `current tab of front window` in that setup. Docs updates and full multi-window verification are deferred to later phases of the same change (see `openspec/changes/multi-document-targeting/tasks.md`).
- **#17 / #18: `safari-browser documents` subcommand** — New discovery command that lists every Safari document's 1-based index, URL, and title in document-collection order — the exact index accepted by `--document N`. Supports `--json` for scripted use. Text output uses `[N] url — title`, matching the listing format embedded in `SafariBrowserError.documentNotFound` so users who hit a not-found error see consistent formatting. Empty Safari (no documents) is a clean exit-0 with no output (text) or `[]` (JSON).

## 2026-04-07 — v2.3.0

### Breaking Changes
- **#14: Upload smart default** — Native file dialog when Accessibility permission is granted, auto-fallback to JS DataTransfer without permission. `AXIsProcessTrusted()` runtime detection. Use `--js` flag to force the old JS DataTransfer behavior.

### Features
- **#14: Clipboard paste for path input** — All file dialog path input now uses clipboard paste (`Cmd+V`) instead of `keystroke` — instant regardless of path length, supports all characters including CJK.
- **#14: Shared `navigateFileDialog`** — Upload and PDF export now share a single dialog navigation function in `SafariBridge.swift`.
- **#14: Precise dialog waits** — All dialog transitions use `repeat until exists` polling instead of blind `delay` — faster and more reliable.
- **#14: AXDefault button** — Locale-independent dialog confirmation using accessibility attribute instead of hardcoded button names.
- **#14: JS upload improvements** — URL navigation check every 10 chunks (not every chunk), ignores `#` fragment, `window.__sbUpload` cleanup on abort.

## 2026-04-06 — v2.2.0

### Removed
- **Channel / MCP server** — Removed vision monitor channel (`channel.ts`, `.mcp.json`, `safari_action` / `safari_monitor_*` tools) from the plugin. Source code retained in repo but no longer loaded as a plugin component. Replaced by upcoming `snapshot --page` (#13) for AI page awareness.

## 2026-04-06 — v2.1.0

### Features
- **#12: Monitor pause/resume MCP tools** — Channel now exposes `safari_monitor_pause`, `safari_monitor_resume`, `safari_monitor_status`. Claude can silence the vision monitor during multi-step `safari_action` sequences to avoid stale/transitional `page_change` events, then resume for post-action observation.
- **#12: lastEventAt tracking** — `safari_monitor_status` reports `{ enabled, paused, running, interval_ms, last_event_at }` for runtime introspection.

## 2026-04-04 — v2.0.1

### Bug Fixes
- **#10: Channel monitor now opt-in** — `SB_CHANNEL_MONITOR=1` required to enable the vision monitor loop. Previously the loop started unconditionally every 1.5s, causing continuous shutter sounds and orphan processes. Reply tool (`safari_action`) still works without the monitor.
- **#10: Silent screenshots** — `screencapture -x` flag added to suppress macOS shutter sound during agent automation.
- **#10: Full cleanup handlers** — Channel server now cleans up interval + temp screenshots on SIGINT/SIGTERM/SIGHUP/exit/stdin-end to prevent orphans.

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
