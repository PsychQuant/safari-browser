import ArgumentParser
import Darwin
import Foundation

struct PdfCommand: AsyncParsableCommand {
    /// Replace the GUI boundary only in tests; real CLI runs use the native flow.
    @TaskLocal static var nativeExporter: (@Sendable (String) async throws -> Void)?

    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Export page as PDF (requires --allow-hid for keyboard simulation)"
    )

    @Argument(help: "Output file path (default: page.pdf)")
    var path: String = "page.pdf"

    @Flag(name: .long, help: "Allow keyboard/mouse simulation (required for PDF export)")
    var allowHid = false

    @Flag(name: .long, help: "Allow replacing an existing PDF destination (also requires --allow-hid)")
    var overwrite = false

    /// #26: pdf now accepts the full TargetOptions (`--url`, `--tab`,
    /// `--document`, `--window`). The native-path resolver maps each
    /// targeting flag to a physical window + tab-in-window. When the
    /// target is a background tab, the export script makes it the current
    /// tab of its window (`SafariBridge.bringTabForwardStatements`) before
    /// the PDF export menu/dialog keystroke sequence runs.
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

        let destination = try Self.effectiveDestination(path, overwrite: overwrite)
        let published = try await PDFExportTransaction.run(destination: destination, overwrite: overwrite) { staging, deadline in
            if let nativeExporter = Self.nativeExporter {
                try await nativeExporter(staging.path)
            } else {
                try await exportNative(to: staging.path, deadline: deadline)
            }
        }
        print("PDF saved to \(TerminalText.escaped(published.path))")
    }

    /// Validate raw directory semantics before extension normalization, so an
    /// existing directory or directory symlink cannot become a different file.
    static func effectiveDestination(_ path: String, overwrite: Bool) throws -> URL {
        guard !path.utf8.contains(0) else { throw ValidationError("PDF destination contains a NUL character.") }
        guard !path.isEmpty, !path.hasSuffix("/") else { throw ValidationError("PDF destination must be a file, not a directory.") }
        let expanded = (path as NSString).expandingTildeInPath
        let raw = URL(fileURLWithPath: expanded)
        try validateDestination(raw.path, overwrite: true)
        let destination = raw.pathExtension.isEmpty ? raw.appendingPathExtension("pdf") : raw
        try validateDestination(destination.path, overwrite: overwrite)
        return destination
    }

    /// What the native export is about to run: the one export script, and the target a miss is worded for.
    struct ExportPlan {
        let script: String
        let missTarget: SafariBridge.TargetDocument
        let profile: String?
        /// Whether the resolution found the target in a background tab, so that the user is told a tab will
        /// be brought forward. The script itself checks the named tab either way.
        let switchesTab: Bool
    }

    /// Everything the native export does before the keyboard is touched (#353): `--window N` becomes the
    /// window's id once (#354), the target is resolved, and the export script is built to name that window by
    /// its id. A bad window index or URL pattern throws `documentNotFound` / `ambiguousWindowMatch` here, so a
    /// typo never shows the "Controlling keyboard…" warning for a run that sends no key. Separate from
    /// `exportNative` so a test can drive it against a fake Safari: the script itself goes straight to
    /// `osascript`.
    func plannedExport(stagingPath: String, remaining: () throws -> TimeInterval) async throws -> ExportPlan {
        let target = try await self.target.pinWindowAtStart()
        let profile = target.resolveProfile()
        let named = target.resolve()
        let resolved = try await SafariBridge.resolveWindowLevelTarget(
            named: named, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: profile)
        let script = PdfCommand.exportScript(
            path: stagingPath,
            window: SafariBridge.actingWindow(for: resolved, named: named, profile: profile),
            tab: resolved.anchorTabIndex,
            guardClause: SafariBridge.tabGuardClause(named: named, matchedURL: resolved.matchedURL),
            timeout: try remaining())
        return ExportPlan(
            script: script,
            missTarget: SafariBridge.actedTarget(for: resolved, named: named, profile: profile),
            profile: profile,
            switchesTab: resolved.tabIndexInWindow != nil)
    }

    private func exportNative(to stagingPath: String, deadline: PDFExportDeadline) async throws {
        try deadline.check()
        let plan = try await plannedExport(stagingPath: stagingPath, remaining: { try deadline.remaining() })

        // Tab switch is a passively interfering side effect transitively
        // authorized by --allow-hid. Emit the addendum before the
        // keyboard takeover warning so users see the full interaction
        // plan up front.
        for line in Self.exportNotices(switchesTab: plan.switchesTab) {
            FileHandle.standardError.write(Data(line.utf8))
        }
        try deadline.check()

        // One osascript for the whole flow, the tab switch included (#353): it used to be a separate Apple
        // event before this script, and before #106 the flow was three scripts, with the gaps between them
        // open to another app taking focus. The window always raises explicitly, even with no targeting flag
        // (a no-op for a window that is already frontmost). The navigation body is the fragment `upload`
        // embeds too (#105).
        do {
            let remaining = try deadline.remaining()
            try await SafariBridge.translatingWindowLevelMarkers(target: plan.missTarget, profile: plan.profile) {
                try await SafariBridge.runFileDialogScript(plan.script, timeout: remaining)
            }
        } catch {
            if Self.needsRecoveryAdvice(after: error) {
                FileHandle.standardError.write(Data("PDF native export failed; inspect Safari and cancel any remaining save dialog before retrying. If the process was interrupted, the clipboard may need restoration.\n".utf8))
            }
            throw error
        }
    }

    /// Whether a failed export may have left a save dialog or a changed clipboard behind. An error raised in
    /// the script's first Safari block (the window or the tab is gone, or the tab failed its URL check) comes
    /// before any menu action, raise or clipboard write, and says so itself; advice to cancel a save dialog
    /// after it would contradict it.
    static func needsRecoveryAdvice(after error: Error) -> Bool {
        switch error {
        case SafariBrowserError.documentNotFound: return false
        case SafariBrowserError.targetChangedBeforeActing(_, .beforeAnyAction): return false
        default: return true
        }
    }

    /// What goes to stderr before the export script runs, in order: the tab-switch notice when the target is a
    /// background tab, then the keyboard warning.
    static func exportNotices(switchesTab: Bool) -> [String] {
        var lines: [String] = []
        if switchesTab {
            lines.append("ℹ️  Target tab will be brought to the front of its window before PDF export.\n")
        }
        lines.append("⚠️  Controlling keyboard for PDF export. Do not type until complete.\n")
        return lines
    }

    static func validateDestination(_ path: String, overwrite: Bool) throws {
        try PDFExportTransaction.validateDestination(path: path, overwrite: overwrite)
    }

    /// The single combined script the export runs. Pure, so its atomicity and
    /// its use of the shared navigation fragment are testable without opening a
    /// save dialog (#106).
    ///
    /// What cannot be tested that way is whether it *works* — that needs a real
    /// save panel, and a failure there wedges every later Safari command (#67).
    /// The issue records that limitation rather than implying the unit tests
    /// cover it.
    ///
    /// #353: `window` is how the script names the window. By id, the first Safari block checks that the window
    /// still exists (a missing one ends the script with `SB_WINDOW_GONE` before any menu action). When the
    /// resolution named a tab (`tab`), the block then binds it, runs `guardClause` when the tab was found by its
    /// URL, and makes it current when it is not: a tab that was already current is checked too. Then it reads
    /// the page URL, raises the window and activates. By position it is the block sent before #353, with the
    /// same tab statements folded in.
    static func exportScript(
        path: String,
        window: SafariBridge.ActingWindow,
        tab: Int? = nil,
        guardClause: String? = nil,
        timeout: TimeInterval = 60
    ) -> String {
        let reference = window.reference
        var open: [String] = []
        if let id = window.windowID {
            open.append(SafariBridge.windowGoneCheck(windowID: id))
            open.append("set pdfWindowID to \(id)")
        } else {
            open.append("set pdfWindowID to id of \(reference)")
        }
        if let tab {
            open += SafariBridge.bringTabForwardStatements(windowReference: reference, tab: tab, guardClause: guardClause)
        }
        open += [
            "set pdfPageURL to URL of current tab of \(reference)",
            "set index of \(reference) to 1",
            "activate",
        ]
        let openBlock = open.joined(separator: "\n    ")
        return """
        on verifyPDFOwner(expectedID, expectedURL)
            tell application "Safari"
                if not (exists window id expectedID) then error "PDF target window disappeared"
                if id of front window is not expectedID then error "PDF target window changed; cancel the save dialog before retrying"
                if URL of current tab of front window is not expectedURL then error "PDF target page changed; cancel the save dialog before retrying"
            end tell
            tell application "System Events" to tell process "Safari"
                if not frontmost then error "Safari lost focus during PDF export; cancel the save dialog before retrying"
            end tell
        end verifyPDFOwner

        on checkPDFDeadline(endTime)
            if (current date) >= endTime then error "PDF export deadline expired; cancel the save dialog before retrying"
        end checkPDFDeadline

        set pdfEndTime to (current date) + \(max(0, timeout))
        tell application "Safari"
            \(openBlock)
        end tell
        delay 0.5
        tell application "System Events"
            tell process "Safari"
                my verifyPDFOwner(pdfWindowID, pdfPageURL)
                my checkPDFDeadline(pdfEndTime)
                if exists sheet 1 of front window then error "Unexpected sheet before PDF export; no menu action was sent"

                -- Resolve only measured Export labels; never fall back to Print.
                set fileMenus to (menu bar items of menu bar 1 whose name is "File" or name is "檔案")
                if (count fileMenus) is not 1 then error "A unique File menu is unavailable for PDF export"
                set exportItems to (menu items of menu 1 of item 1 of fileMenus whose name is "Export as PDF…" or name is "輸出為PDF⋯")
                if (count exportItems) is not 1 then error "A unique Export as PDF menu item is unavailable"
                set exportItem to item 1 of exportItems
                if not (enabled of exportItem) then error "Export as PDF is disabled"
                my verifyPDFOwner(pdfWindowID, pdfPageURL)
                my checkPDFDeadline(pdfEndTime)
                click exportItem

                repeat until exists sheet 1 of front window
                    my verifyPDFOwner(pdfWindowID, pdfPageURL)
                    my checkPDFDeadline(pdfEndTime)
                    delay 0.1
                end repeat

        \(SafariBridge.fileDialogNavigationScript(path: path, pdfSave: true))

        \(completionWaitScript())
            end tell
        end tell
        """
    }

    /// UI completion is necessary, but publication still requires an independent
    /// valid PDF snapshot. No extra confirmation is expected at a unique path.
    static func completionWaitScript() -> String {
        """
        repeat
            my verifyPDFOwner(pdfWindowID, pdfPageURL)
            my checkPDFDeadline(pdfEndTime)
            if not (exists sheet 1 of front window) then exit repeat
            if exists sheet 1 of sheet 1 of front window then error "Unexpected PDF staging confirmation; no replacement was sent. Cancel the save dialog before retrying"
            delay 0.1
        end repeat
        my verifyPDFOwner(pdfWindowID, pdfPageURL)
        my checkPDFDeadline(pdfEndTime)
        """
    }
}
