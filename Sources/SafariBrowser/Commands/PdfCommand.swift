import ArgumentParser
import Foundation

struct PdfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Export page as PDF"
    )

    @Argument(help: "Output file path (default: page.pdf)")
    var path: String = "page.pdf"

    func run() async throws {
        let absolutePath = (path as NSString).standardizingPath
        let fullPath = absolutePath.hasPrefix("/") ? absolutePath : FileManager.default.currentDirectoryPath + "/" + path

        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "Safari" to activate
            delay 0.5
            tell application "System Events"
                tell process "Safari"
                    -- File > Export as PDF
                    click menu item "Export as PDF…" of menu "File" of menu bar 1
                    delay 1

                    -- Wait for save dialog
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.5
                        set waited to waited + 0.5
                        if waited >= maxWait then
                            error "Save dialog did not appear"
                        end if
                    end repeat

                    -- Cmd+Shift+G to enter path
                    keystroke "g" using {command down, shift down}
                    delay 1

                    -- Type path
                    keystroke "\(fullPath)"
                    keystroke return
                    delay 1

                    -- Click Save
                    click button "Save" of sheet 1 of front window
                    delay 1

                    -- Handle replace dialog if file exists
                    if exists sheet 1 of sheet 1 of front window then
                        click button "Replace" of sheet 1 of sheet 1 of front window
                    end if
                end tell
            end tell
            """])
    }
}
