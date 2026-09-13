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

    private func exportNative(to stagingPath: String, deadline: PDFExportDeadline) async throws {
        try deadline.check()
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
        try deadline.check()
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
        do {
            let remaining = try deadline.remaining()
            try await SafariBridge.runFileDialogScript(
                PdfCommand.exportScript(path: stagingPath, windowIndex: resolved.windowIndex, timeout: remaining),
                timeout: remaining)
        } catch {
            FileHandle.standardError.write(Data("PDF native export failed; inspect Safari and cancel any remaining save dialog before retrying. If the process was interrupted, the clipboard may need restoration.\n".utf8))
            throw error
        }
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
    static func exportScript(path: String, windowIndex: Int, timeout: TimeInterval = 60) -> String {
        """
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
            set pdfWindowID to id of window \(windowIndex)
            set pdfPageURL to URL of current tab of window \(windowIndex)
            set index of window \(windowIndex) to 1
            activate
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
