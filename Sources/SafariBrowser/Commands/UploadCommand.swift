import ArgumentParser
import Foundation

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a file via the file dialog"
    )

    @Argument(help: "CSS selector of the file input element")
    var selector: String

    @Argument(help: "Path to the file to upload")
    var filePath: String

    func run() async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // Click the file input to open the dialog
        let clickResult = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
        )
        if clickResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }

        // Use System Events to navigate the file dialog
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "System Events"
                tell process "Safari"
                    -- Wait for file dialog
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.5
                        set waited to waited + 0.5
                        if waited >= maxWait then
                            error "File dialog did not appear"
                        end if
                    end repeat

                    -- Cmd+Shift+G to open path input
                    keystroke "g" using {command down, shift down}
                    delay 1

                    -- Type the file path
                    keystroke "\(expandedPath)"
                    keystroke return
                    delay 1

                    -- Click Open
                    keystroke return
                end tell
            end tell
            """])
    }
}
