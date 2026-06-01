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

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let allDocuments = try await SafariBridge.listAllDocuments()
        // Apply --profile filter (Issue #47) at the listing layer so
        // `documents --profile X` enumerates only the requested
        // profile's tabs. Other lock flags (--url, --window, etc.) are
        // not applied here — `documents` is for *discovery*, not
        // single-tab targeting.
        let profileFilter = target.resolveProfile()
        let documents: [SafariBridge.DocumentInfo]
        if let profile = profileFilter {
            documents = allDocuments.filter { $0.profile == profile }
        } else {
            documents = allDocuments
        }

        if json {
            let array = documents.map { doc in
                [
                    "index": doc.index,
                    "window": doc.window,
                    "tab_in_window": doc.tabInWindow,
                    "is_current": doc.isCurrent,
                    "url": doc.url,
                    "title": doc.title,
                    // profile is always present in JSON output (NSNull
                    // when no profile detected) — additive change for
                    // automation parsers, easier than conditional schema.
                    "profile": doc.profile as Any? ?? NSNull(),
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
        // #46: emit the active-tab legend to stderr so humans can decode the
        // '*' marker, while stdout stays a bit-stable parseable tab list
        // (scripts that pipe stdout are unaffected; for programmatic active
        // detection use --json's is_current field).
        FileHandle.standardError.write(Data(DocumentsCommand.legendLine().utf8))
        for line in DocumentsCommand.formatText(documents) {
            print(line)
        }
    }

    /// One-line legend explaining the `*` active-tab marker in text output.
    /// Emitted to stderr (never stdout) so the parseable tab list stays
    /// bit-stable for scripts. Pure helper for unit testing. #46.
    static func legendLine() -> String {
        "documents: '*' marks the active tab of each window (live snapshot; "
            + "each window has one, so multiple '*' across windows is normal — "
            + "for scripting use the is_current field from --json).\n"
    }

    /// Pure formatter for the text output mode. Exposed for unit testing
    /// independently of Safari.
    ///
    /// Issue #47: when ANY document in the list has a non-nil profile,
    /// the formatter inserts a `[profile]` column between the
    /// `wN.tM` coordinates and the URL. When the entire list has
    /// `profile == nil` (single-profile or pre-Safari 17 setups), the
    /// column is omitted — preserving bit-exact output for users who
    /// don't have multi-profile enabled (zero break for legacy parsers).
    static func formatText(_ documents: [SafariBridge.DocumentInfo]) -> [String] {
        let hasAnyProfile = documents.contains { $0.profile != nil }
        // #56: pad the [profile] column to the widest bracketed value so the
        // URL column stays aligned across variable-length profile names.
        // Width is by Character count; CJK names occupy fewer display columns
        // than their count, so alignment is exact only for same-script names
        // (true display-width alignment is out of scope — see #56).
        let profileCols = documents.map { "[\($0.profile ?? "-")]" }
        let profileColWidth = profileCols.map(\.count).max() ?? 0
        return documents.enumerated().map { index, doc in
            let marker = doc.isCurrent ? "*" : " "
            let coords = "w\(doc.window).t\(doc.tabInWindow)"
            let body = "\(doc.url) — \(doc.title)"
            if hasAnyProfile {
                let raw = profileCols[index]
                let profileCol = raw + String(repeating: " ", count: max(0, profileColWidth - raw.count))
                return "[\(doc.index)] \(marker) \(coords)  \(profileCol)  \(body)"
            }
            return "[\(doc.index)] \(marker) \(coords)  \(body)"
        }
    }
}
