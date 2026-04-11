import ArgumentParser
import Foundation

/// Lists every Safari document across all windows so users can discover
/// which index / URL substring to pass to the global targeting flags
/// (`--url`, `--window`, `--tab`, `--document`). Complements the
/// `SafariBrowserError.documentNotFound` error, whose description uses
/// the same listing format. Part of the multi-document-targeting change
/// (#17 / #18 / #21).
struct DocumentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "documents",
        abstract: "List all Safari documents (index, URL, title) for target discovery"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func run() async throws {
        let documents = try await SafariBridge.listAllDocuments()

        if json {
            let array = documents.map { doc in
                [
                    "index": doc.index,
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

        // Text mode: `[N] url — title` per document. Matches the error-list
        // format in SafariBrowserError.documentNotFound so users who see
        // that error and then run `documents` see identical formatting.
        if documents.isEmpty {
            // Empty Safari state — print nothing, exit 0.
            return
        }
        for doc in documents {
            print("[\(doc.index)] \(doc.url) — \(doc.title)")
        }
    }
}
