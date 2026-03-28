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

    func run() async throws {
        let windowID = try SafariBridge.getWindowID()

        if full {
            // Get full page dimensions and current scroll position
            let dims = try await SafariBridge.doJavaScript(
                "JSON.stringify({sw:document.documentElement.scrollWidth,sh:document.documentElement.scrollHeight,cw:document.documentElement.clientWidth,ch:document.documentElement.clientHeight,sx:window.scrollX,sy:window.scrollY})"
            )

            // Save current window bounds
            let bounds = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                tell application "Safari"
                    get bounds of front window
                end tell
                """])

            // Resize window to full page size
            if let data = dims.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sw = json["sw"] as? Int,
               let sh = json["sh"] as? Int {
                let width = min(sw + 50, 3000)  // cap to reasonable size
                let height = min(sh + 150, 10000)
                _ = try await SafariBridge.doJavaScript("window.scrollTo(0,0)")
                try await Task.sleep(nanoseconds: 300_000_000)
                try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                    tell application "Safari"
                        set bounds of front window to {0, 0, \(width), \(height)}
                    end tell
                    """])
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            // Take screenshot, always restore window bounds afterward
            var captureError: Error?
            do {
                try await SafariBridge.runShell("/usr/sbin/screencapture", ["-l", windowID, path])
            } catch {
                captureError = error
            }

            // Restore window bounds (always, even if capture failed)
            _ = try? await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
                tell application "Safari"
                    set bounds of front window to {\(bounds)}
                end tell
                """])

            // Restore scroll position
            if let data = dims.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sx = json["sx"] as? Int,
               let sy = json["sy"] as? Int {
                _ = try? await SafariBridge.doJavaScript("window.scrollTo(\(sx),\(sy))")
            }

            if let captureError { throw captureError }
        } else {
            try await SafariBridge.runShell("/usr/sbin/screencapture", ["-l", windowID, path])
        }
    }
}
