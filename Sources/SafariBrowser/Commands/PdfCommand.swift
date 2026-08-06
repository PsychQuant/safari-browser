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
        let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())

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

        // The resolved window index always raises explicitly — even when the
        // user passed no targeting flag (resolved windowIndex is 1, the front
        // window), because the raise is a no-op for an already-frontmost window
        // and keeping one code path is worth more than skipping it.
        //
        // One osascript for the whole flow. It used to be three, with the gaps
        // between them open to another app taking focus — the race #15 closed
        // for `upload` and #106 for this command. The navigation body is the
        // fragment `upload` embeds too (#105), so there is one source of truth
        // without either caller giving up atomicity.
        try await SafariBridge.runShell(
            "/usr/bin/osascript",
            ["-e", PdfCommand.exportScript(path: fullPath, windowIndex: resolved.windowIndex)])
    }

    /// The single combined script the export runs. Pure, so its atomicity and
    /// its use of the shared navigation fragment are testable without opening a
    /// save dialog (#106).
    ///
    /// What cannot be tested that way is whether it *works* — that needs a real
    /// save panel, and a failure there wedges every later Safari command (#67).
    /// The issue records that limitation rather than implying the unit tests
    /// cover it.
    static func exportScript(path: String, windowIndex: Int) -> String {
        """
        tell application "Safari" to set index of window \(windowIndex) to 1
        tell application "Safari" to activate
        delay 0.5
        tell application "System Events"
            tell process "Safari"
                -- Verify Safari is frontmost before touching menus or keys
                if not frontmost then
                    error "Safari lost focus after activate — aborting to avoid acting on the wrong application"
                end if

                -- NOTE: Menu labels are English. On non-English macOS this cannot
                -- resolve, and the script aborts here rather than hanging — the
                -- wait loop below is never reached. See docs/operation-paths.md §4.2.
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

        \(SafariBridge.fileDialogNavigationScript(path: path))

                -- "<file> already exists. Replace?" — only present when it is.
                -- #107: announced, because pressing it confirms an overwrite the
                -- caller never saw.
                delay 0.5
                if exists sheet 1 of sheet 1 of front window then
                    try
                        set replaceBtn to (first button of sheet 1 of sheet 1 of front window whose value of attribute "AXDefault" is true)
                        log "confirming replace sheet: pressing default button \\"" & (title of replaceBtn) & "\\""
                        click replaceBtn
                    on error
                        log "confirming replace sheet: default-button press unavailable, falling back to Return keystroke"
                        keystroke return
                    end try
                end if
            end tell
        end tell
        """
    }
}
