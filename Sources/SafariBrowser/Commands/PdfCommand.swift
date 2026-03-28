import ArgumentParser
import Foundation

struct PdfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Export page as PDF (requires --allow-hid for keyboard simulation)"
    )

    @Argument(help: "Output file path (default: page.pdf)")
    var path: String = "page.pdf"

    @Flag(name: .long, help: "Allow keyboard/mouse simulation (required for PDF export)")
    var allowHid = false

    func run() async throws {
        guard allowHid else {
            FileHandle.standardError.write(Data("""
                PDF export requires System Events (keyboard/mouse simulation).
                Re-run with --allow-hid:
                  safari-browser pdf --allow-hid "\(path)"
                ⚠️  --allow-hid will control your keyboard. Do not type until it completes.

                """.utf8))
            throw SafariBrowserError.appleScriptFailed("PDF export requires --allow-hid flag")
        }

        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for PDF export. Do not type until complete.\n".utf8))

        let absolutePath = (path as NSString).standardizingPath
        let fullPath = absolutePath.hasPrefix("/") ? absolutePath : FileManager.default.currentDirectoryPath + "/" + path

        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "Safari" to activate
            delay 0.5
            tell application "System Events"
                tell process "Safari"
                    -- NOTE: Menu labels are English. On non-English macOS, use keyboard shortcut instead.
                    -- Cmd+P → "PDF" dropdown → "Save as PDF" is locale-independent but more complex.
                    click menu item "Export as PDF…" of menu "File" of menu bar 1
                    delay 1
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.5
                        set waited to waited + 0.5
                        if waited >= maxWait then
                            error "Save dialog did not appear"
                        end if
                    end repeat
                    keystroke "g" using {command down, shift down}
                    delay 1
                    keystroke "\(fullPath.escapedForAppleScript)"
                    keystroke return
                    delay 1
                    click button "Save" of sheet 1 of front window
                    delay 1
                    if exists sheet 1 of sheet 1 of front window then
                        click button "Replace" of sheet 1 of sheet 1 of front window
                    end if
                end tell
            end tell
            """])
    }
}
