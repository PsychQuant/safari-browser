import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Take a screenshot of the Safari window"
    )

    @Argument(help: "Output file path (default: screenshot.png)")
    var path: String = "screenshot.png"

    @Flag(name: .long, help: "Capture full scrollable page")
    var full = false

    /// #29: crop Safari chrome (URL bar, tab bar, toolbar) so the
    /// output PNG contains only the web content area. Requires
    /// Accessibility permission — see `SafariBrowserError
    /// .accessibilityRequired` for why JavaScript fallback is
    /// intentionally rejected.
    @Flag(name: .long, help: "Crop Safari chrome, keep only web content area (requires Accessibility)")
    var contentOnly = false

    /// #30: crop to the bounding rectangle of a DOM element matched by
    /// CSS selector. Uses `querySelectorAll` + `getBoundingClientRect`;
    /// light DOM only (Shadow DOM / iframe content is out of scope).
    /// Requires Accessibility permission for the AXWebArea origin
    /// lookup. Multi-match is fail-closed by default — see
    /// `--element-index` for deterministic disambiguation.
    @Option(name: .long, help: "CSS selector for element-scoped crop (requires Accessibility)")
    var element: String?

    /// #30: 1-indexed disambiguator for multi-match `--element`.
    /// Requires `--element`. Picks the Nth match in document order
    /// (the order returned by `querySelectorAll`).
    @Option(name: .customLong("element-index"), help: "1-indexed match picker for --element (disambiguates multi-match)")
    var elementIndex: Int?

    func validate() throws {
        // #30: --element-index requires --element (can't pick Nth of
        // nothing) and must be positive (document order is 1-indexed).
        if elementIndex != nil && element == nil {
            throw ValidationError("--element-index requires --element")
        }
        if let idx = elementIndex, idx < 1 {
            throw ValidationError("--element-index must be >= 1 (got \(idx))")
        }
    }

    /// #26: screenshot now accepts the full TargetOptions (`--url`,
    /// `--tab`, `--document`, `--window`). The native-path resolver
    /// maps each targeting flag to a window index. Unlike upload / pdf
    /// / close, screenshot **does NOT** tab-switch — per the #26
    /// non-interference spec, screenshot observes without interfering.
    /// If the resolver points at a background tab, the AX path captures
    /// the window's current visible content (which may differ from the
    /// targeted tab). For users who need DOM-level content of a
    /// background tab, the `--full` flag reads page dimensions through
    /// `doJavaScript` on the target document directly and computes a
    /// scrolled capture — but the captured pixels are still window-
    /// level and limited to whatever tab is foregrounded in that window.
    @OptionGroup var target: TargetOptions

    /// #75: `SAFARI_BROWSER_SKIP_SR_PREFLIGHT=1` skips the Screen Recording
    /// preflight. Diagnostic escape hatch for a preflight that misreports —
    /// not a way to run without permission, since the capture itself still
    /// fails, only with a hedged message instead of a precise one.
    static var screenRecordingPreflightDisabled: Bool {
        isTruthyEnvFlag(ProcessInfo.processInfo.environment["SAFARI_BROWSER_SKIP_SR_PREFLIGHT"])
    }

    /// Pure parser so the accepted spellings are testable without mutating the
    /// process environment. Accepts the shapes people actually type; anything
    /// else — including the empty string a bare `export VAR=` leaves behind —
    /// reads as off, because an accidentally-cleared variable must not silently
    /// disable a safety check.
    static func isTruthyEnvFlag(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    func run() async throws {
        // #70: every screenshot path ends in /usr/sbin/screencapture, whose
        // pixel capture requires Screen Recording permission on the
        // CONTROLLING app. Preflight (read-only, never prompts — preserves
        // Non-Interference) so the failure is a named permission error with
        // guidance instead of screencapture's raw stderr surfacing as a
        // misleading "AppleScript error". DELIBERATE ordering: this runs
        // before target/AX validation because the permission is a universal
        // precondition of every screenshot path — in an unauthorized
        // environment the permission error outranks more specific
        // diagnostics (verify #70 round 2 reviewed and accepted this
        // precedence change).
        // #75: the preflight fails closed, so a false negative would make
        // screenshot unusable with no way around it. No such misreport has
        // been observed — this exists because the cost of the escape hatch is
        // one env var and the cost of being wrong without one is total. A
        // bypassed capture that genuinely lacks permission still fails, just
        // via the reactive `isScreenRecordingDenial` rewrap further down, so
        // skipping the preflight trades a precise error for a hedged one
        // rather than trading it for silence.
        if !ScreenshotCommand.screenRecordingPreflightDisabled {
            guard CGPreflightScreenCaptureAccess() else {
                throw SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            }
        }

        // #29 / #30: --content-only and --element both hard-fail
        // without Accessibility. Check BEFORE resolveWindowForCapture
        // so useless AX resolution doesn't run. --element flag takes
        // precedence in the error message (most specific flag first).
        if element != nil && !AXIsProcessTrusted() {
            throw SafariBrowserError.accessibilityRequired(flag: "--element")
        }
        if contentOnly && !AXIsProcessTrusted() {
            throw SafariBrowserError.accessibilityRequired(flag: "--content-only")
        }

        // Preserve the #23 legacy fallback: when the user supplies no
        // targeting flag AND Accessibility permission is absent,
        // `resolveWindowForCapture(window: nil)` takes the CG name-
        // match path which does not require AX. Only resolve to a
        // concrete window index when the user explicitly asked for a
        // target — otherwise the `nil` signal tells the capture
        // resolver to preserve its existing fallback behavior.
        let hasExplicitTarget = target.url != nil
            || target.window != nil
            || target.tab != nil
            || target.document != nil

        let resolvedWindowIndex: Int?
        if hasExplicitTarget {
            let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())

            // #26 verify P1-2: fail-closed when the resolved target is a
            // background tab. Screenshot captures window-level visible
            // pixels — a background-tab target would silently produce
            // the currently-visible (wrong) tab's screenshot. Rather
            // than break the non-interference contract by switching
            // tabs (upload/pdf/close do that explicitly) or silently
            // wrong-target, refuse and point the user at alternatives.
            if resolved.tabIndexInWindow != nil {
                throw SafariBrowserError.backgroundTabNotCapturable(
                    windowIndex: resolved.windowIndex,
                    tabIndex: resolved.tabIndexInWindow ?? -1
                )
            }

            resolvedWindowIndex = resolved.windowIndex
        } else {
            resolvedWindowIndex = nil
        }

        // #23 verify R7: resolve both CG ID AND AX element so --full mode
        // can do bounds operations on the SAME window we're about to
        // capture. This eliminates the R6 F42 cross-API mismatch where
        // CG ID came from AX but bounds resize went through AS `window N`
        // (could be a different window).
        let (windowID, axWindow) = try await SafariBridge.resolveWindowForCapture(window: resolvedWindowIndex)

        // JS target for dimensions / scroll state. Uses the full
        // TargetOptions resolution so `--full --url plaud` reads
        // plaud's dimensions via doJavaScript even when plaud is in a
        // background tab of its owning window.
        // #51: scope the --full JS dimensions read to --profile too (screenshot
        // is honored), and drop the previously-unused firstMatch/warnWriter
        // destructure.
        let docTarget = try await target.resolveProfileScoped()

        if !full {
            // Simple path: capture whatever CG ID resolved. Always silent (-x).
            try await Self.runCapture(windowID: windowID, path: path)
            // Post-capture crop: --element takes precedence over
            // --content-only because element coords are already
            // viewport-relative (chrome-excluded). Combining both is
            // legal per design; --content-only becomes a no-op here.
            // axWindow is guaranteed non-nil — AX hard-fail at top
            // of run() enforces AX for both flags.
            if let element {
                guard let axWindow else {
                    throw SafariBrowserError.imageCroppingFailed(
                        reason: "internal: AX window handle missing despite --element hard-fail check passing"
                    )
                }
                try await applyElementCrop(
                    selector: element,
                    elementIndex: elementIndex,
                    axWindow: axWindow,
                    path: path,
                    docTarget: docTarget
                )
            } else if contentOnly {
                guard let axWindow else {
                    throw SafariBrowserError.imageCroppingFailed(
                        reason: "internal: AX window handle missing despite --content-only hard-fail check passing"
                    )
                }
                try applyContentOnlyCrop(axWindow: axWindow, path: path)
            }
            return
        }

        // --full path: resize, capture, restore. R7 prefers AX bounds ops
        // when axWindow is available (AXIsProcessTrusted + targeted or
        // default-with-permission path). Falls back to AS bounds for the
        // legacy default path (no Accessibility + no --window).

        // Read page dimensions via JS (same window we're capturing).
        let dims = try await SafariBridge.doJavaScript(
            "JSON.stringify({sw:document.documentElement.scrollWidth,sh:document.documentElement.scrollHeight,cw:document.documentElement.clientWidth,ch:document.documentElement.clientHeight,sx:window.scrollX,sy:window.scrollY})",
            target: docTarget
        )

        var savedRect: CGRect? = nil
        var asBoundsRaw: String? = nil

        if let axWindow {
            savedRect = try SafariBridge.getAXWindowBounds(axWindow)
        } else {
            // Legacy default-no-AX path — AS `front window` is coherent here
            // because the nil case used `getFrontWindowID` which matches
            // whatever Safari's AS front window is.
            asBoundsRaw = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                tell application "Safari"
                    get bounds of front window
                end tell
                """])
        }

        // Parse dims JSON once.
        var targetW: Int? = nil
        var targetH: Int? = nil
        var scrollX: Int? = nil
        var scrollY: Int? = nil
        if let data = dims.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sw = json["sw"] as? Int, let sh = json["sh"] as? Int {
                targetW = min(sw + 50, 3000)
                targetH = min(sh + 150, 10000)
            }
            scrollX = json["sx"] as? Int
            scrollY = json["sy"] as? Int
        }

        // #23 verify R7 F55: R8 wraps resize in a do-catch and tracks
        // the error separately. If resize throws, we still run the
        // restore block below (which may be a no-op if save also
        // failed). This avoids leaving the window half-resized when
        // the new strict `setAXWindowBounds` (R8 F54) throws on
        // fullscreen / minimized targets.
        var resizeError: Error?
        if let targetW, let targetH {
            do {
                _ = try await SafariBridge.doJavaScript("window.scrollTo(0,0)", target: docTarget)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let axWindow {
                    try SafariBridge.setAXWindowBounds(axWindow, x: 0, y: 0, width: Double(targetW), height: Double(targetH))
                } else {
                    try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                        tell application "Safari"
                            set bounds of front window to {0, 0, \(targetW), \(targetH)}
                        end tell
                        """])
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                resizeError = error
            }
        }

        // Capture — skipped if resize failed (nothing to capture at
        // the expected size). Still fall through to restore so the
        // save path can undo any partial mutation.
        var captureError: Error?
        var cropError: Error?
        if resizeError == nil {
            do {
                try await Self.runCapture(windowID: windowID, path: path)
            } catch {
                captureError = error
            }
            // #29 / #30: post-capture crop. Both --element and
            // --content-only are measured AFTER resize (AXWebArea
            // origin + element's getBoundingClientRect both change
            // with viewport size) and BEFORE restore.
            //
            // Pre-measured bounds sidestep the #29 post-resize AX race
            // (kAXPositionAttribute intermittently returns noValue
            // within ~500ms of setAXWindowBounds). We just set the
            // window to (0, 0, targetW, targetH) via AX, so pass those
            // directly. getAXWebAreaBounds + getElementBoundsInViewport
            // are still called — those are the post-resize measurements
            // the design requires.
            //
            // --element takes precedence over --content-only in the
            // combined case per design (element crop is strictly more
            // specific).
            if let element, captureError == nil, let axWindow, let targetW, let targetH {
                let postResizeBounds = CGRect(
                    x: 0,
                    y: 0,
                    width: Double(targetW),
                    height: Double(targetH)
                )
                do {
                    try await applyElementCrop(
                        selector: element,
                        elementIndex: elementIndex,
                        axWindow: axWindow,
                        path: path,
                        docTarget: docTarget,
                        preMeasuredWindowBounds: postResizeBounds
                    )
                } catch {
                    cropError = error
                }
            } else if contentOnly, captureError == nil, let axWindow, let targetW, let targetH {
                let postResizeBounds = CGRect(
                    x: 0,
                    y: 0,
                    width: Double(targetW),
                    height: Double(targetH)
                )
                do {
                    try applyContentOnlyCrop(
                        axWindow: axWindow,
                        path: path,
                        preMeasuredWindowBounds: postResizeBounds
                    )
                } catch {
                    cropError = error
                }
            }
        }

        // Restore bounds. Always run, even on capture failure. R9 F58:
        // capture restoreError separately so we can warn the user when
        // the window is left in a non-original state.
        var restoreError: Error?
        if let axWindow, let rect = savedRect {
            do {
                try SafariBridge.setAXWindowBounds(
                    axWindow,
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y),
                    width: Double(rect.size.width),
                    height: Double(rect.size.height)
                )
            } catch {
                restoreError = error
            }
        } else if let asBoundsRaw {
            do {
                _ = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                    tell application "Safari"
                        set bounds of front window to {\(asBoundsRaw)}
                    end tell
                    """])
            } catch {
                restoreError = error
            }
        }

        // Restore scroll position. Less critical (page state) so still
        // best-effort; failure not warned.
        if let sx = scrollX, let sy = scrollY {
            _ = try? await SafariBridge.doJavaScript("window.scrollTo(\(sx),\(sy))", target: docTarget)
        }

        // R9 F58: if restore failed, warn on stderr regardless of
        // whether resize/capture also failed. The user needs to know
        // their window may be left at the resize dimensions.
        if let restoreError {
            FileHandle.standardError.write(Data(
                "⚠️  Window bounds restore failed: \(restoreError.localizedDescription) — window state may be modified.\n".utf8
            ))
        }

        // R8 F55: propagate resize error first (command never ran the
        // actual capture in that case), then capture error. User sees
        // the root cause, not a downstream symptom. #29: crop error
        // propagates last — it only happens when resize+capture both
        // succeeded, so showing it as the final error is meaningful.
        if let resizeError { throw resizeError }
        if let captureError { throw captureError }
        if let cropError { throw cropError }
    }

    /// #70: shared capture wrapper for both the plain and `--full` paths.
    /// Rewraps a screencapture denial-signature failure (detected via
    /// `isScreenRecordingDenial`) as `screenRecordingRequired(
    /// postPreflight: true, underlying:)`. The preflight at the top of
    /// run() already passed by the time we get here, so the failure is
    /// EITHER a stale TCC grant OR a window-lifecycle race — the same
    /// stderr fires for vanished/invalid window IDs in a fully-granted
    /// environment (verify #70 round 1, empirically confirmed with
    /// `screencapture -l 999999999`). The error message presents both
    /// hypotheses and carries the original stderr so the user can
    /// disambiguate. Unrelated failures propagate unchanged.
    static func runCapture(windowID: String, path: String) async throws {
        do {
            try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
        } catch {
            if isScreenRecordingDenial(errorText: "\(error)") {
                throw SafariBrowserError.screenRecordingRequired(
                    postPreflight: true, underlying: underlyingText(from: error))
            }
            throw error
        }
    }

    /// #70: extract the raw stderr from a runShell failure for display.
    /// Unwraps runShell's generic appleScriptFailed shell-wrapper so the
    /// message doesn't echo its misleading "AppleScript error" prefix
    /// (that mislabel is #73's scope); any other error falls back to its
    /// interpolated description. Pure — unit-tested.
    static func underlyingText(from error: Error) -> String {
        if case .appleScriptFailed(let stderrText)? = error as? SafariBrowserError {
            return stderrText
        }
        return "\(error)"
    }

    /// #70: detect screencapture's capture-denial stderr signatures —
    /// exactly "could not create image from window" / "... from display"
    /// (case-insensitive). Verify round 2 narrowed this from the bare
    /// "could not create image" prefix: the full signatures are what
    /// screencapture actually emits for capture denial, and a broader
    /// prefix would rewrap unrelated future messages (e.g. "could not
    /// create image file") as permission errors, violating the
    /// "unrelated failures propagate unchanged" contract. Deliberately
    /// NARROWER than the e2e matcher it pairs with (`is_capture_denied`,
    /// Tests/e2e-test.sh — also greps not authorized / kCGError / ...):
    /// under-matching just lets the raw error propagate, while
    /// over-matching misdirects users into TCC remediation. NOTE the
    /// signature is NOT unique to permission denial — it also fires for
    /// vanished/invalid window IDs, which is why the rewrapped message
    /// presents both hypotheses. Pure — unit-tested.
    static func isScreenRecordingDenial(errorText: String) -> Bool {
        let lowered = errorText.lowercased()
        return lowered.contains("could not create image from window")
            || lowered.contains("could not create image from display")
    }

    /// #29: crop the captured PNG so it contains only the Safari web
    /// content area (AXWebArea), excluding URL bar, tab bar, and
    /// toolbar. Called from both the simple path and the --full path;
    /// the caller is responsible for ordering w.r.t. resize/restore.
    ///
    /// **No-op threshold** (design.md §"No-op threshold"): when the
    /// AXWebArea width matches the window width and the height delta
    /// is under 4 points, the window has effectively no chrome
    /// (fullscreen / Reader Mode) and we skip the crop — writing the
    /// captured PNG unchanged. Tolerance is absolute, not
    /// percentage, to avoid false positives on near-fullscreen windows
    /// with small toolbars.
    /// - Parameters:
    ///   - axWindow: resolved Safari AX window element
    ///   - path: PNG file to crop in place
    ///   - preMeasuredWindowBounds: when the caller already knows the
    ///     window's bounds (e.g. the --full path just called
    ///     `setAXWindowBounds` to place the window at a known rect),
    ///     pass them here to skip a redundant AX query. Avoiding the
    ///     extra query sidesteps a race where `kAXPositionAttribute`
    ///     briefly returns `noValue` during the resize settle phase.
    private func applyContentOnlyCrop(
        axWindow: AXUIElement,
        path: String,
        preMeasuredWindowBounds: CGRect? = nil
    ) throws {
        do {
            let windowBounds: CGRect
            if let preMeasuredWindowBounds {
                windowBounds = preMeasuredWindowBounds
            } else {
                windowBounds = try SafariBridge.getAXWindowBounds(axWindow)
            }
            let webAreaScreen = try SafariBridge.getAXWebAreaBounds(axWindow)

            // No-op: viewport effectively fills window (fullscreen, Reader
            // Mode). Threshold logic is in ImageCropping so unit tests can
            // exercise it without spinning up an AX window. The un-cropped
            // capture IS the desired output here, so return WITHOUT removing.
            if ImageCropping.isNoOpCrop(windowBounds: windowBounds, webAreaBounds: webAreaScreen) {
                return
            }

            // Window-relative rect: AX returns screen-absolute coords; the
            // captured PNG's image-space origin (0,0) corresponds to the
            // window's top-left. Subtract to translate.
            let rectInWindow = CGRect(
                x: webAreaScreen.origin.x - windowBounds.origin.x,
                y: webAreaScreen.origin.y - windowBounds.origin.y,
                width: webAreaScreen.width,
                height: webAreaScreen.height
            )
            try ImageCropping.cropPNG(
                at: path,
                rectPoints: rectInWindow,
                windowWidthPoints: windowBounds.width
            )
        } catch {
            // #44: on ANY crop failure (AX frame read or cropPNG), remove the
            // un-cropped capture so callers don't find a misleading
            // chrome-included file at the path (mirrors applyElementCrop) — the
            // error message promises no file is left behind.
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    /// #30: crop the captured PNG to the bounding rectangle of a DOM
    /// element selected via CSS selector. Called from both the simple
    /// path and the --full path; the caller supplies pre-measured
    /// window bounds in --full mode to avoid the post-resize AX race.
    ///
    /// Coordinate translation: the JS `getBoundingClientRect` returns
    /// viewport-relative points. Window-relative coords = viewport
    /// coords + (AXWebArea.origin − window.origin). Then cropPNG
    /// applies the HiDPI scale conversion.
    ///
    /// **On any error**, the un-cropped captured PNG at `path` is
    /// removed so the spec's "no file written on element error"
    /// contract holds. The original error is then re-thrown.
    private func applyElementCrop(
        selector: String,
        elementIndex: Int?,
        axWindow: AXUIElement,
        path: String,
        docTarget: SafariBridge.TargetDocument,
        preMeasuredWindowBounds: CGRect? = nil
    ) async throws {
        do {
            let windowBounds: CGRect
            if let preMeasuredWindowBounds {
                windowBounds = preMeasuredWindowBounds
            } else {
                windowBounds = try SafariBridge.getAXWindowBounds(axWindow)
            }
            let webAreaScreen = try SafariBridge.getAXWebAreaBounds(axWindow)

            let result = try await SafariBridge.getElementBoundsInViewport(
                selector: selector,
                target: docTarget,
                elementIndex: elementIndex
            )

            // viewport-relative + (webArea.origin − window.origin) = window-relative
            let elementRectInWindow = CGRect(
                x: (webAreaScreen.origin.x - windowBounds.origin.x) + result.rectInViewport.origin.x,
                y: (webAreaScreen.origin.y - windowBounds.origin.y) + result.rectInViewport.origin.y,
                width: result.rectInViewport.size.width,
                height: result.rectInViewport.size.height
            )

            try ImageCropping.cropPNG(
                at: path,
                rectPoints: elementRectInWindow,
                windowWidthPoints: windowBounds.width
            )
        } catch {
            // Remove the un-cropped capture so the user doesn't see a
            // misleading chrome-included file on element failure.
            // Best-effort: ignore removal errors (file may not exist
            // if capture itself failed upstream).
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }
}
