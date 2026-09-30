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

    static func removingFragment(_ url: String) -> String {
        url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
    }

    static func redact(_ url: String) -> Redacted {
        let withoutFragment = removingFragment(url)
        guard let query = withoutFragment.firstIndex(of: "?") else {
            return Redacted(display: withoutFragment, hadQuery: false)
        }
        return Redacted(display: String(withoutFragment[..<query]), hadQuery: true)
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
    static func select(tabURL: String, from pdfs: [WebKitCachedPDF]) throws -> WebKitCachedPDF {
        let wanted = PDFCacheURL.removingFragment(tabURL)
        let subject = "the tab's URL \(PDFCacheURL.redact(tabURL).display)"
        return try single(pdfs.filter { $0.requestURL == wanted }, subject: subject)
    }

    /// Case-insensitive prefix of the record key. A body whose record cannot be
    /// read still counts as a match, so a prefix never quietly skips past it.
    static func select(keyPrefix: String, scan: WebKitCacheReader.Scan) throws -> WebKitCachedPDF {
        let prefix = keyPrefix.uppercased()
        let matches = scan.pdfs.filter { $0.key.uppercased().hasPrefix(prefix) }
        let unreadable = scan.unreadableKeys.filter { $0.uppercased().hasPrefix(prefix) }
        let subject = "key prefix \(keyPrefix)"
        if matches.isEmpty, unreadable.count == 1 {
            throw SafariBrowserError.pdfCache(.unreadableRecord(key: unreadable[0]))
        }
        if matches.count + unreadable.count > 1 {
            let lines = matches.map { PDFCacheFormat.candidateLine($0) }
                + unreadable.map { "\($0.prefix(12))  (record unreadable)" }
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

    private static func single(_ matches: [WebKitCachedPDF], subject: String) throws -> WebKitCachedPDF {
        switch matches.count {
        case 1: return matches[0]
        case 0: throw SafariBrowserError.pdfCache(.noMatch(subject: subject))
        default:
            throw SafariBrowserError.pdfCache(.ambiguous(
                subject: subject, candidates: matches.map { PDFCacheFormat.candidateLine($0) }))
        }
    }
}
