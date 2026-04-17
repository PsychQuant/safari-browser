import ArgumentParser
import Foundation

/// Lists every Safari tab across all windows so users can discover
/// which index / URL substring / `(window, tab-in-window)` coordinate
/// to pass to the global targeting flags (`--url`, `--window`,
/// `--tab-in-window`, `--document`). Complements the
/// `SafariBrowserError.documentNotFound` error, whose description uses
/// the same listing format.
///
/// Output is tab-level (one line per tab, including background tabs),
/// not window-level — per the `human-emulation` principle, the tab bar
/// is the ground truth a user sees, so the CLI enumerates the same
/// thing.
struct DocumentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "documents",
        abstract: "List all Safari tabs (index, window, tab-in-window, URL, title) for target discovery"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func run() async throws {
        let documents = try await SafariBridge.listAllDocuments()

        if json {
            let array = documents.map { doc in
                [
                    "index": doc.index,
                    "window": doc.window,
                    "tab_in_window": doc.tabInWindow,
                    "is_current": doc.isCurrent,
                    "url": doc.url,
                    "title": doc.title,
                ] as [String: Any]
            }
            let data = try JSONSerialization.data(
                withJSONObject: array,
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        if documents.isEmpty {
            return
        }
        for line in DocumentsCommand.formatText(documents) {
            print(line)
        }
    }

    /// Pure formatter for the text output mode. Exposed for unit testing
    /// independently of Safari.
    static func formatText(_ documents: [SafariBridge.DocumentInfo]) -> [String] {
        documents.map { doc in
            let marker = doc.isCurrent ? "*" : " "
            return "[\(doc.index)] \(marker) w\(doc.window).t\(doc.tabInWindow)  \(doc.url) — \(doc.title)"
        }
    }
}
