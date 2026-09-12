import Foundation

/// Counts malformed records before application filtering. Diagnostics contain
/// fixed schema names and numeric locations, never data-controlled field values.
struct SchemaDiagnostics {
    let sourceURL: URL
    let context: String
    private(set) var validCount = 0
    private(set) var invalidCount = 0
    private var examples: [String] = []

    init(sourceURL: URL, context: String) {
        self.sourceURL = sourceURL
        self.context = context
    }

    mutating func valid() { validCount += 1 }

    mutating func invalid(at location: String, field: String) {
        invalidCount += 1
        if examples.count < 8 { examples.append("\(location).\(field)") }
    }

    func finish() throws {
        guard invalidCount > 0 else { return }
        let locations = examples.joined(separator: ", ")
        let remainder = invalidCount > examples.count ? "; further locations omitted" : ""
        let detail = "\(context): \(invalidCount) malformed entry/entries among examined records (\(locations)\(remainder))"
        guard validCount > 0 else {
            throw SafariBrowserError.safariDataParseFailed(path: sourceURL.path, detail: detail)
        }
        LocalDataOutput.writeStderr("Warning: skipped \(detail).\n")
    }

    static func requiredString(_ value: Any?) -> String? {
        guard let string = value as? String,
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    /// Foundation Date accepts values far outside the public four-digit CE
    /// representation. DateFormatter/ISO8601DateFormatter can otherwise emit
    /// empty strings, clipped years, or a positive year for a BCE instant.
    static func representableDate(_ value: Date?, timeZone: TimeZone = .current) -> Date? {
        guard let value else { return nil }
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year], from: value)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year) else { return nil }
        return value
    }

    static func plist(_ data: Data, sourceURL: URL) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw SafariBrowserError.safariDataParseFailed(
                path: sourceURL.path, detail: "property list decoding failed: \(error.localizedDescription)")
        }
    }
}
