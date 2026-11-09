import ArgumentParser
import Foundation

struct TabsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List all open tabs"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        // `tabs` lists tabs of a window — document-level targeting doesn't
        // make sense, so reject everything except --window / --window-id (and
        // the no-flag default, which means front window).
        if target.url != nil || target.urlExact != nil || target.urlEndswith != nil || target.urlRegex != nil
            || target.tab != nil || target.document != nil || target.tabInWindow != nil {
            throw ValidationError(
                "`tabs` only supports --window or --window-id for targeting; --url, --url-exact, --url-endswith, --url-regex, --tab, --document, and --tab-in-window are not allowed."
            )
        }
    }

    /// #362: the window the resolver produced must still be open. The check is keyed on the id it resolved
    /// to, not on the flag typed, so `--profile` and `--window N` report a window that closed during the
    /// command as a targeting miss, as `--window-id` does (#352), instead of a raw -1728 or an empty list.
    /// `readError` is the object-not-found error that made the read fail, if one did.
    private func requireOpen(_ resolved: SafariBridge.ResolvedWindowTarget, typed base: SafariBridge.TargetDocument,
                             profile: String?, after readError: Error? = nil) async throws {
        let windows: [SafariBridge.WindowInfo]
        do {
            windows = try await SafariBridge.listAllWindows()
        } catch {
            // #362 verify F4: the check could not run, so nothing says the window closed. What is known is
            // that the read failed: report that. A cancellation stays a cancellation.
            if let readError, !(error is CancellationError) { throw readError }
            throw error
        }
        guard let id = resolved.windowID else {
            // No id was read: resolving what was typed again fails when that window is not open.
            _ = try SafariBridge.pickNativeTarget(base, in: windows, profile: profile)
            return
        }
        do {
            try SafariBridge.checkWindowID(id, profile: profile, in: windows)
        } catch SafariBrowserError.documentNotFound(_, let available) where target.windowID == nil {
            let typed = [target.window.map { "--window \($0)" }, profile.map { "--profile \"\($0)\"" }]
                .compactMap { $0 }.joined(separator: " ")
            throw SafariBrowserError.documentNotFound(
                pattern: "window id \(id) (\(typed)), closed during the command", availableDocuments: available)
        }
    }

    private static func isObjectNotFound(_ error: Error) -> Bool {
        if case SafariBrowserError.appleScriptFailed(let message) = error { return SafariBridge.isObjectNotFound(message) }
        return false
    }

    func run() async throws {
        let tabs: [SafariBridge.TabInfo]
        let profile = target.resolveProfile()
        // #352 / #362: a named window (`--window-id`, `--window N`, `--profile`) goes through the resolver, which
        // finds the window (by id it fails closed when it is missing or outside --profile); `listTabs(in:)` then
        // reads it by the id it resolved to. No flag reads the front window, and no window at all is no tabs.
        if target.windowID != nil || target.window != nil || profile != nil {
            let base: SafariBridge.TargetDocument = target.windowID.map { .windowID($0) }
                ?? target.window.map { .windowIndex($0) } ?? .frontWindow
            let resolved = try await SafariBridge.resolveNativeTarget(
                from: base, firstMatch: target.firstMatch,
                warnWriter: TargetOptions.stderrWarnWriter, profile: profile, probeDialog: false)
            do {
                tabs = try await SafariBridge.listTabs(in: resolved, probeDialog: false)
            } catch where Self.isObjectNotFound(error) {
                try await requireOpen(resolved, typed: base, profile: profile, after: error)
                throw error
            }
            // `readTabs` answers "no tabs" when no window is open at all.
            if tabs.isEmpty { try await requireOpen(resolved, typed: base, profile: profile) }
        } else {
            tabs = try await SafariBridge.listTabs(probeDialog: false)
        }
        guard !tabs.isEmpty else {
            if json { print("[]") }
            return
        }
        let observation = WindowDialogObservation.capture()
        if (target.window != nil || target.windowID != nil || target.resolveProfile() != nil),
           let windowID = tabs.first?.windowID,
           let dialog = observation.singleDialog(for: windowID) {
            DocumentsCommand.emitDialogWarning(BlockingDialogWarning.firstLine(windowKey: .id(windowID), dialog: dialog) + "\n")
        }
        if json {
            DocumentsCommand.emitDialogWarning(DocumentsCommand.dialogWarnings(commandName: "tabs",
                statuses: tabs.map { observation.status(for: $0.windowID) }, includeLegend: false))
            let arr = Self.jsonRows(tabs, observation: observation)
            let data = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            let dialogWarning = DocumentsCommand.dialogWarnings(commandName: "tabs", statuses: tabs.map { observation.status(for: $0.windowID) })
            DocumentsCommand.emitDialogWarning(dialogWarning)
            for line in Self.formatText(tabs, observation: observation) {
                print(line)
            }
        }
    }

    static func jsonRows(
        _ tabs: [SafariBridge.TabInfo], observation: WindowDialogObservation
    ) -> [[String: Any]] {
        tabs.map { tab in
            ["index": tab.index, "title": tab.title, "url": tab.url,
             "blocking_dialog": observation.status(for: tab.windowID).jsonObject]
        }
    }

    static func formatText(
        _ tabs: [SafariBridge.TabInfo], observation: WindowDialogObservation
    ) -> [String] {
        tabs.map { tab in
            let row = "\(tab.index)\t\(tab.title)\t\(tab.url)"
            guard let suffix = observation.status(for: tab.windowID).textSuffix else { return row }
            return row + "\t" + suffix
        }
    }
}
