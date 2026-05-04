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

    /// #26: pdf now accepts the full TargetOptions (`--url`, `--tab`,
    /// `--document`, `--window`). The native-path resolver maps each
    /// targeting flag to a physical window + tab-in-window. When the
    /// target is a background tab, `performTabSwitchIfNeeded` brings it
    /// to the front of its window before the PDF export menu/dialog
    /// keystroke sequence runs.
    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "pdf")
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

        // #26: route through the native-path resolver. The resolver
        // short-circuits for .frontWindow / .windowIndex (preserving the
        // #23 behavior for --window N / no flag) and enumerates windows
        // only for --url / --tab / --document. Preflight is implicit in
        // the resolver — a bad window index / URL pattern throws
        // documentNotFound or ambiguousWindowMatch before any stderr
        // warning, so users with a typo never see the misleading
        // "Controlling keyboard..." message for a run that fails
        // immediately without touching the keyboard.
        let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)

        // Tab switch is a passively interfering side effect transitively
        // authorized by --allow-hid. Emit the addendum before the
        // keyboard takeover warning so users see the full interaction
        // plan up front.
        if resolved.tabIndexInWindow != nil {
            FileHandle.standardError.write(Data(
                "ℹ️  Target tab will be brought to the front of its window before PDF export.\n".utf8
            ))
        }
        try await SafariBridge.performTabSwitchIfNeeded(
            window: resolved.windowIndex,
            tab: resolved.tabIndexInWindow
        )

        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for PDF export. Do not type until complete.\n".utf8))

        // The resolved window index always raises explicitly — even
        // when the user passed no targeting flag (resolved windowIndex
        // is 1, corresponding to front window / document 1), the raise
        // AppleScript is a no-op for an already-frontmost window, so
        // we keep the code path uniform.
        let raisePrelude = """
            tell application "Safari" to set index of window \(resolved.windowIndex) to 1
            """

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
