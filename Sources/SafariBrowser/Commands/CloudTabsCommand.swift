import ArgumentParser
import Foundation

/// One tab open on another iCloud-connected device (#109).
struct CloudTab: Equatable {
    let device: String
    let title: String
    let url: String
}

/// Lists tabs currently open on the user's other iCloud devices.
///
/// Note this is *not* historical data despite living alongside the history
/// commands: it reflects what is open right now elsewhere. That is why it
/// carries no default limit — same reasoning as `bookmarks`.
///
/// `CloudTabs.db` is absent on any Mac that never enabled iCloud tab syncing,
/// which is a normal configuration and exits 0 rather than erroring.
struct CloudTabsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloud-tabs",
        abstract: "List tabs open on your other iCloud devices (requires Full Disk Access)"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    // MARK: - Query

    /// Column order: device name, title, url.
    ///
    /// The schema is queried defensively — Safari's cloud-tab tables have
    /// changed shape across releases, so a failure here reports the parse
    /// layer rather than pretending the file was unreadable.
    static let sql = """
        SELECT d.device_name, t.title, t.url
        FROM cloud_tabs t
        LEFT JOIN cloud_tab_devices d ON d.device_uuid = t.device_uuid
        ORDER BY d.device_name, t.title
        """

    static func tabs(inDatabaseAt url: URL) throws -> [CloudTab] {
        try SQLiteReader.query(at: url, sql: sql) { row -> CloudTab? in
            guard row.count >= 3, let tabURL = row[2].stringValue else { return nil }
            return CloudTab(
                device: row[0].stringValue ?? "(unknown device)",
                title: row[1].stringValue ?? "",
                url: tabURL)
        }
    }

    // MARK: - Formatting

    static func formatRow(index: Int, tab: CloudTab) -> String {
        let title = tab.title.replacingOccurrences(of: "\n", with: " ")
        let suffix = title.isEmpty ? "" : " — \(title)"
        return "[\(index)]  \(tab.device)  \(tab.url)\(suffix)"
    }

    static func encodeJSON(_ tabs: [CloudTab]) throws -> Data {
        let payload = tabs.map { ["device": $0.device, "title": $0.title, "url": $0.url] }
        if payload.isEmpty { return Data("[]".utf8) }
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Run

    func run() throws {
        let results: [CloudTab]
        do {
            results = try SafariDataStore.withCopy(.cloudTabs) { copy in
                try CloudTabsCommand.tabs(inDatabaseAt: copy)
            }
        } catch let error as SafariBrowserError {
            if case .safariDataFileNotFound = error {
                LocalDataOutput.reportAbsentSource(.cloudTabs, json: json)
                return
            }
            throw error
        }

        try LocalDataOutput.emit(
            json: json,
            jsonData: { try CloudTabsCommand.encodeJSON(results) },
            textRows: results.enumerated().map { index, tab in
                CloudTabsCommand.formatRow(index: index + 1, tab: tab)
            },
            legend: "cloud-tabs: [N]  device  url — title  (no default limit)")
    }
}
