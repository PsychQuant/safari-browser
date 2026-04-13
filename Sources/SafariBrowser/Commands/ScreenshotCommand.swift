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

    @OptionGroup var windowTarget: WindowOnlyTargetOptions

    func run() async throws {
        // #23 verify R7: resolve both CG ID AND AX element so --full mode
        // can do bounds operations on the SAME window we're about to
        // capture. This eliminates the R6 F42 cross-API mismatch where
        // CG ID came from AX but bounds resize went through AS `window N`
        // (could be a different window).
        let (windowID, axWindow) = try await SafariBridge.resolveWindowForCapture(window: windowTarget.window)

        // JS target for dimensions / scroll state. Uses the same window
        // index the user passed via CLI (or front window for nil).
        let docTarget = windowTarget.resolveAsTargetDocument()

        if !full {
            // Simple path: capture whatever CG ID resolved. Always silent (-x).
            try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
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
        if resizeError == nil {
            do {
                try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
            } catch {
                captureError = error
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
        // the root cause, not a downstream symptom.
        if let resizeError { throw resizeError }
        if let captureError { throw captureError }
    }
}
