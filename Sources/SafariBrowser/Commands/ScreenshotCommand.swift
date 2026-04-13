import ArgumentParser
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
        let windowID = try SafariBridge.getWindowID(window: windowTarget.window)
        // AppleScript window reference used for bounds operations — the
        // same one `getWindowID` resolved above, so the captured CG window
        // and the resized Safari window stay in sync (#23).
        let windowRef = windowTarget.window.map { "window \($0)" } ?? "front window"
        // JavaScript-scoped target for the dimensions / scroll state — we
        // bounce through `--document <n>` when `--window <n>` is given so
        // the dimensions belong to the same window we're about to capture.
        let docTarget: SafariBridge.TargetDocument = windowTarget.window.map { .documentIndex($0) } ?? .frontWindow

        if full {
            // Get full page dimensions and current scroll position
            let dims = try await SafariBridge.doJavaScript(
                "JSON.stringify({sw:document.documentElement.scrollWidth,sh:document.documentElement.scrollHeight,cw:document.documentElement.clientWidth,ch:document.documentElement.clientHeight,sx:window.scrollX,sy:window.scrollY})",
                target: docTarget
            )

            // Save current window bounds
            let bounds = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                tell application "Safari"
                    get bounds of \(windowRef)
                end tell
                """])

            // Resize window to full page size
            if let data = dims.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sw = json["sw"] as? Int,
               let sh = json["sh"] as? Int {
                let width = min(sw + 50, 3000)  // cap to reasonable size
                let height = min(sh + 150, 10000)
                _ = try await SafariBridge.doJavaScript("window.scrollTo(0,0)", target: docTarget)
                try await Task.sleep(nanoseconds: 300_000_000)
                try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                    tell application "Safari"
                        set bounds of \(windowRef) to {0, 0, \(width), \(height)}
                    end tell
                    """])
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            // Take screenshot, always restore window bounds afterward.
            // -x: silent mode (no shutter sound) — required for agent automation (#10)
            var captureError: Error?
            do {
                try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
            } catch {
                captureError = error
            }

            // Restore window bounds (always, even if capture failed)
            _ = try? await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                tell application "Safari"
                    set bounds of \(windowRef) to {\(bounds)}
                end tell
                """])

            // Restore scroll position
            if let data = dims.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sx = json["sx"] as? Int,
               let sy = json["sy"] as? Int {
                _ = try? await SafariBridge.doJavaScript("window.scrollTo(\(sx),\(sy))", target: docTarget)
            }

            if let captureError { throw captureError }
        } else {
            // -x: silent mode (no shutter sound) — required for agent automation (#10)
            try await SafariBridge.runShell("/usr/sbin/screencapture", ["-x", "-l", windowID, path])
        }
    }
}
