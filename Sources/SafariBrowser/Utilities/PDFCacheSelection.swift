import ArgumentParser
import Foundation

/// Where `pdf-cache` reads from. The network cache is the default; the
/// `WebKitPDFs-*` folders exist only after a person pressed "Open with
/// Preview", so they are never used unless asked for.
enum PDFCacheSource: String, ExpressibleByArgument, CaseIterable {
    case cache
    case webkitPDFs = "webkit-pdfs"
}

/// Query strings on signed URLs can be credentials, so every URL that is
/// shown is reduced to scheme, host and path. Matching still uses the full
/// string; only display is reduced.
enum PDFCacheURL {
    struct Redacted: Equatable {
        let display: String
        let hadQuery: Bool
    }

    /// Delimiters are found among Unicode scalars, not `Character`s: a combining
    /// mark after `?` makes one grapheme cluster that is not equal to `?`, and a
    /// search by `Character` would then miss the query it was meant to cut.
    static func removingFragment(_ url: String) -> String {
        let scalars = url.unicodeScalars
        guard let hash = scalars.firstIndex(of: "#") else { return url }
        return String(scalars[..<hash])
    }

    static func redact(_ url: String) -> Redacted {
        let withoutFragment = removingFragment(url)
        let scalars = withoutFragment.unicodeScalars
        guard let query = scalars.firstIndex(of: "?") else {
            return Redacted(display: withoutFragment, hadQuery: false)
        }
        return Redacted(display: String(scalars[..<query]), hadQuery: true)
    }

    /// Swift's `==` on strings treats canonically equivalent text as equal; a
    /// URL match is by bytes.
    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

/// Choosing which cached PDF `get` copies (#210).
///
/// The selection forms are a closed list of three — a tab flag, `--key`, and
/// `--source webkit-pdfs --file` — and nothing is ever chosen on the caller's
/// behalf: not the newest, not the largest, not the only one. A selection that
/// matches nothing or several stops with the candidates listed.
enum PDFCacheSelection {
    static let minimumKeyPrefix = 8

    enum Form: Equatable {
        case tab
        case key(String)
        case file(String)
    }

    /// A malformed combination of flags, as opposed to a valid selection that
    /// found nothing. Surfaced as a usage error before anything is read.
    struct UsageError: Error, Equatable {
        let message: String
    }

    static func form(hasTab: Bool, key: String?, file: String?, source: PDFCacheSource) throws -> Form {
        var given: [String] = []
        if hasTab { given.append("a tab flag") }
        if key != nil { given.append("--key") }
        if file != nil { given.append("--file") }
        if given.count > 1 {
            throw UsageError(message: "Give exactly one selection; got \(given.joined(separator: " and ")).")
        }
        switch source {
        case .cache:
            if file != nil {
                throw UsageError(message: "--file selects from the WebKitPDFs folders; add --source webkit-pdfs.")
            }
        case .webkitPDFs:
            if hasTab { throw UsageError(message: "Tab flags select from the network cache; they cannot be combined with --source webkit-pdfs.") }
            if key != nil { throw UsageError(message: "--key selects from the network cache; it cannot be combined with --source webkit-pdfs.") }
        }
        if hasTab { return .tab }
        if let key {
            let isHex = key.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
            guard key.count >= minimumKeyPrefix, isHex else {
                throw UsageError(message: "--key needs at least \(minimumKeyPrefix) hexadecimal characters of the key shown by `pdf-cache list`.")
            }
            return .key(key)
        }
        if let file {
            guard !file.isEmpty else { throw UsageError(message: "--file needs a file name.") }
            return .file(file)
        }
        throw SafariBrowserError.pdfCache(.selectionRequired)
    }

    // MARK: - Matching

    /// The tab's URL, with its fragment removed, must equal a record's request
    /// URL exactly. No normalisation: a different query, a trailing slash, an
    /// explicit port or a different case is a different resource, and a
    /// near-match that copied the wrong PDF would look exactly like success.
    static func select(tabURL: String, from pdfs: [WebKitCachedPDF], unreadNote: String? = nil) throws -> WebKitCachedPDF {
        let wanted = PDFCacheURL.removingFragment(tabURL)
        let subject = "the tab's URL \(PDFCacheURL.redact(tabURL).display)"
        return try single(pdfs.filter { PDFCacheURL.isSame($0.requestURL, wanted) }, subject: subject, unreadNote: unreadNote)
    }

    /// The tab form over a whole scan: a miss says so when part of the cache could not be read.
    static func select(tabURL: String, scan: WebKitCacheReader.Scan) throws -> WebKitCachedPDF {
        try select(tabURL: tabURL, from: scan.pdfs, unreadNote: unreadNote(scan))
    }

    /// `nil` when everything in the cache was understood.
    static func unreadNote(_ scan: WebKitCacheReader.Scan) -> String? {
        var parts: [String] = []
        if scan.unreadableRecords > 0 { parts.append("\(scan.unreadableRecords) with a record that cannot be read") }
        if !scan.partialKeys.isEmpty { parts.append("\(scan.partialKeys.count) that hold only a byte range") }
        if !scan.outOfSyncKeys.isEmpty { parts.append("\(scan.outOfSyncKeys.count) whose record does not describe its body") }
        guard !parts.isEmpty else { return nil }
        return "The cache also holds PDF bodies that were not considered: \(parts.joined(separator: ", ")). The one you mean may be among them; see `pdf-cache list`."
    }

    /// Case-insensitive prefix of the record key. A body whose record cannot be
    /// read still counts as a match, so a prefix never quietly skips past it.
    static func select(keyPrefix: String, scan: WebKitCacheReader.Scan) throws -> WebKitCachedPDF {
        let prefix = keyPrefix.uppercased()
        let matches = scan.pdfs.filter { $0.key.uppercased().hasPrefix(prefix) }
        let unreadable = scan.unreadableKeys.filter { $0.uppercased().hasPrefix(prefix) }
        let partial = scan.partialKeys.filter { $0.uppercased().hasPrefix(prefix) }
        let outOfSync = scan.outOfSyncKeys.filter { $0.uppercased().hasPrefix(prefix) }
        let subject = "key prefix \(keyPrefix)"
        let others = unreadable.count + partial.count + outOfSync.count
        if matches.isEmpty, others == 1 {
            if let key = partial.first { throw SafariBrowserError.pdfCache(.partialBody(key: key)) }
            if let key = unreadable.first { throw SafariBrowserError.pdfCache(.unreadableRecord(key: key)) }
            if let key = outOfSync.first { throw SafariBrowserError.pdfCache(.recordDisagrees(key: key)) }
        }
        if matches.count + others > 1 {
            let lines = matches.map { PDFCacheFormat.candidateLine($0) }
                + unreadable.map { "\($0.prefix(12))  (record unreadable)" }
                + partial.map { "\($0.prefix(12))  (byte range only, cannot be copied)" }
                + outOfSync.map { "\($0.prefix(12))  (record and body disagree, cannot be copied)" }
            throw SafariBrowserError.pdfCache(.ambiguous(subject: subject, candidates: lines))
        }
        return try single(matches, subject: subject)
    }

    static func select(fileName: String, from pdfs: [TemporaryPDF]) throws -> TemporaryPDF {
        let matches = pdfs.filter { $0.name == fileName }
        let subject = "file name \(fileName)"
        switch matches.count {
        case 1: return matches[0]
        case 0: throw SafariBrowserError.pdfCache(.noMatch(subject: subject))
        default:
            throw SafariBrowserError.pdfCache(.ambiguous(
                subject: subject, candidates: matches.map { PDFCacheFormat.candidateLine($0) }))
        }
    }

    private static func single(_ matches: [WebKitCachedPDF], subject: String, unreadNote: String? = nil) throws -> WebKitCachedPDF {
        switch matches.count {
        case 1: return matches[0]
        case 0: throw SafariBrowserError.pdfCache(.noMatch(subject: subject, unreadNote: unreadNote))
        default:
            throw SafariBrowserError.pdfCache(.ambiguous(
                subject: subject, candidates: matches.map { PDFCacheFormat.candidateLine($0) }))
        }
    }
}
