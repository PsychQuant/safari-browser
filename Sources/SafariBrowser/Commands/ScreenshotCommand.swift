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

    func run() async throws {
        // #29: --content-only hard-fails without Accessibility. Check
        // BEFORE resolveWindowForCapture so we don't do useless AX
        // resolution work when the whole command is about to error.
        // Distinct error case from accessibilityNotGranted because the
        // workarounds differ (that case can fall back by dropping
        // --window N; --content-only cannot fall back to a JS heuristic
        // by design — see design.md §"AX fallback").
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
            let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve())

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
        let docTarget = target.resolve()

        if !full {
            // Simple path: capture whatever CG ID resolved. Always silent (-x).
            try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
            // #29: crop Safari chrome post-capture. axWindow is
            // guaranteed non-nil because the AX hard-fail at the top
            // of run() rejects --content-only before we reach here
            // without Accessibility — every resolveWindowForCapture
            // path returns non-nil axWindow when AX is granted.
            if contentOnly {
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
                try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
            } catch {
                captureError = error
            }
            // #29: --full --content-only crop. Must happen AFTER
            // capture (so the PNG exists) and BEFORE restore (so the
            // AXWebArea bounds we read reflect the resized window —
            // design.md §"--full --content-only combo" requires
            // post-resize measurement because chrome can collapse on
            // certain resize dimensions). axWindow is guaranteed
            // non-nil here — the --full path always takes the AX
            // resolver branch (see R7 architecture comments above).
            //
            // Pre-measured bounds: the post-resize AX query for window
            // position/size is flaky within ~500ms of `setAXWindowBounds`
            // (observed intermittent `noSafariWindow` from `axPoint`
            // returning nil during the resize settle). We already set
            // the window to (0, 0, targetW, targetH), so pass those
            // directly instead of re-reading from AX. `getAXWebAreaBounds`
            // is still called (needed to detect chrome collapse) and
            // remains the only AX read in this crop step.
            if contentOnly, captureError == nil, let axWindow, let targetW, let targetH {
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
        let windowBounds: CGRect
        if let preMeasuredWindowBounds {
            windowBounds = preMeasuredWindowBounds
        } else {
            windowBounds = try SafariBridge.getAXWindowBounds(axWindow)
        }
        let webAreaScreen = try SafariBridge.getAXWebAreaBounds(axWindow)

        // No-op: viewport effectively fills window (fullscreen, Reader
        // Mode). Threshold logic is in ImageCropping so unit tests can
        // exercise it without spinning up an AX window.
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
    }
}
