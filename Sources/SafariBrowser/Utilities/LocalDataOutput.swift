import Foundation

/// Output discipline shared by the four local-data-query commands (#109).
///
/// The rule it enforces is the one `documents` established in #46: explanatory
/// text goes to stderr, parseable rows go to stdout. That is what makes
/// `safari-browser history 2>/dev/null | cut -f2` work without anyone having
/// to strip a banner first.
enum LocalDataOutput {

    static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Emits either the JSON array or the text rows, with the legend on stderr.
    ///
    /// `jsonData` is a closure rather than a value so callers do not pay for
    /// encoding output that the text path will never print.
    static func emit(
        json: Bool,
        jsonData: () throws -> Data,
        textRows: [String],
        legend: String
    ) throws {
        if json {
            let data = try jsonData()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        // Legend first and only when there is something to label — a legend
        // above zero rows is noise, and on stderr it cannot be filtered by
        // the usual stdout pipeline.
        if !textRows.isEmpty {
            writeStderr(legend + "\n")
        }
        for row in textRows {
            print(row)
        }
    }

    /// A data file that simply is not there.
    ///
    /// Exits the command successfully: `CloudTabs.db` is absent on every Mac
    /// that never turned on iCloud tab syncing, which is a configuration
    /// state and not a failure. Treating it as an error would make a normal
    /// setup look broken.
    static func reportAbsentSource(_ file: SafariDataFile, json: Bool) {
        writeStderr(
            """
            No \(file.describedSource) on this Mac — \(file.filename) does not exist.
            This is normal when the corresponding Safari feature has never been used.

            """)
        if json {
            print("[]")
        }
    }
}
