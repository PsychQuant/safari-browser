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
        // make sense, so reject everything except --window (and the no-flag
        // default, which means front window).
        if target.url != nil || target.tab != nil || target.document != nil {
            throw ValidationError(
                "`tabs` only supports --window for targeting; --url, --tab, and --document are not allowed."
            )
        }
    }

    func run() async throws {
        let tabs: [SafariBridge.TabInfo]
        if let profile = target.resolveProfile() {
            let base: SafariBridge.TargetDocument = target.window.map { .windowIndex($0) } ?? .frontWindow
            let resolved = try await SafariBridge.resolveNativeTarget(
                from: base, firstMatch: target.firstMatch,
                warnWriter: TargetOptions.stderrWarnWriter, profile: profile, probeDialog: false)
            tabs = try await SafariBridge.listTabs(in: resolved, probeDialog: false)
        } else {
            tabs = try await SafariBridge.listTabs(window: target.window, probeDialog: false)
        }
        guard !tabs.isEmpty else {
            if json { print("[]") }
            return
        }
        let observation = WindowDialogObservation.capture()
        if (target.window != nil || target.resolveProfile() != nil),
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
