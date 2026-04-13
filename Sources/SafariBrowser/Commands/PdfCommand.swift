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

    @OptionGroup var windowTarget: WindowOnlyTargetOptions

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

        let absolutePath = (path as NSString).standardizingPath
        let fullPath = absolutePath.hasPrefix("/") ? absolutePath : FileManager.default.currentDirectoryPath + "/" + path

        // #23: PDF export is keystroke-driven and inherently window-scoped —
        // menu clicks and sheet waits resolve against whichever window we
        // put in front. When --window N is supplied, raise that window to
        // the front before activating Safari, so both `click menu item`
        // and `sheet 1 of front window` land on the requested window.
        let windowIndex = windowTarget.window
        // #23 verify R1→R2: preflight the window so a bad `--window 99`
        // surfaces `documentNotFound` with the available-docs listing
        // BEFORE we print the keyboard-takeover warning and touch
        // System Events. R2 moves the preflight ahead of the stderr
        // warning so users with bad `--window N` never see a misleading
        // "Controlling keyboard..." message for a run that fails
        // immediately without touching the keyboard.
        if let idx = windowIndex {
            _ = try await SafariBridge.getCurrentURL(target: .windowIndex(idx))
        }

        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for PDF export. Do not type until complete.\n".utf8))

        let raisePrelude = windowIndex.map { idx in
            """
            tell application "Safari" to set index of window \(idx) to 1
            """
        } ?? ""

        // Step 1: Activate Safari and open the Export as PDF dialog
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            \(raisePrelude)
            tell application "Safari" to activate
            delay 0.5
            tell application "System Events"
                tell process "Safari"
                    -- NOTE: Menu labels are English. On non-English macOS, use keyboard shortcut instead.
                    -- Cmd+P → "PDF" dropdown → "Save as PDF" is locale-independent but more complex.
                    click menu item "Export as PDF…" of menu "File" of menu bar 1
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.2
                        set waited to waited + 0.2
                        if waited >= maxWait then
                            error "Save dialog did not appear within " & maxWait & " seconds"
                        end if
                    end repeat
                end tell
            end tell
            """])

        // Step 2: Navigate to path and click Save via shared helper
        try await SafariBridge.navigateFileDialog(path: fullPath)

        // Step 3: Handle "Replace" confirmation if file already exists
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "System Events"
                tell process "Safari"
                    delay 0.5
                    if exists sheet 1 of sheet 1 of front window then
                        try
                            click (first button of sheet 1 of sheet 1 of front window whose value of attribute "AXDefault" is true)
                        on error
                            keystroke return
                        end try
                    end if
                end tell
            end tell
            """])
    }
}
