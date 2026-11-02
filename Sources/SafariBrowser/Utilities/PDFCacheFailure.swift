import Foundation

/// Why a `pdf-cache` command stopped (#210).
///
/// A closed list. Every case says what was seen, because the record format is
/// private to WebKit: the next macOS that reshapes it should be diagnosable
/// from one error message. None of these is reinterpreted as "no PDF cached" —
/// telling the caller the cache is empty when the reader could not understand
/// it is the failure this command is built to avoid.
enum PDFCacheFailure: Equatable, Sendable {
    /// What a selection that matched several can do next.
    enum AmbiguousNextStep: Equatable, Sendable {
        case longerKey
        case tabHolds
        case folderAndName
    }

    /// `WebKitCache/` itself is absent.
    case cacheFolderMissing(path: String)
    /// `WebKitCache/` exists but has no `Version 17`; `seen` lists the `Version *` folders it does have.
    case noSupportedVersion(path: String, seen: [String])
    /// PDF bodies exist and none of their records parse (or `Records/` is absent).
    case recordLayoutUnsupported(detail: String)
    /// `get` was called without one of the three selection forms.
    case selectionRequired
    /// A selection matched nothing. `subject` is already redacted for display. `unreadNote` is set
    /// when the cache also holds PDFs this command could not interpret (unreadable records, byte
    /// ranges, a record that disagrees with its body): "nothing matches" would then be a claim
    /// about a cache that was not fully understood.
    case noMatch(subject: String, unreadNote: String? = nil, fromTab: Bool = false, fromFile: Bool = false)
    /// A selection matched several; `candidates` are display lines, not chosen between. What can be
    /// done next depends on the form: `--key` is refused with `--file`, and nothing ties a key to a tab.
    case ambiguous(subject: String, candidates: [String], next: AmbiguousNextStep = .longerKey)
    /// `--key` named a body whose record cannot be read.
    case unreadableRecord(key: String)
    /// `--key` named a body that is only a byte range of a resource, not a document.
    case partialBody(key: String)
    /// `--key` named a body whose record describes a body of another length: WebKit was writing or
    /// replacing one of the two.
    case recordDisagrees(key: String)
    /// The selected body does not start with `%PDF-`.
    case notAPDF(name: String)
    /// The copy starts with `%PDF-` but CoreGraphics cannot read a page from it.
    case unreadablePDF(detail: String)
    case destinationExists(path: String)
    case destinationDirectoryMissing(path: String)
    case destinationWriteFailed(path: String, detail: String)

    var message: String {
        func t(_ text: String) -> String { TerminalText.escaped(text) }
        switch self {
        case .cacheFolderMissing(let path):
            return "Safari's WebKit cache folder does not exist: \(t(path))"
        case .noSupportedVersion(let path, let seen):
            let found = seen.isEmpty ? "none" : seen.map(t).joined(separator: ", ")
            return """
                The WebKit cache at \(t(path)) has no 'Version 17' folder (found: \(found)).
                pdf-cache only understands that layout: the record format is private to WebKit \
                and changes between versions, so it stops instead of guessing.
                """
        case .recordLayoutUnsupported(let detail):
            return """
                Cached PDF bodies were found but their records could not be read as the \
                'Version 17' layout this command understands: \(t(detail))
                The record format is private to WebKit; this is not the same as an empty cache.
                """
        case .selectionRequired:
            return """
                pdf-cache get needs an explicit selection. Give exactly one of:
                  1. a tab flag: --url, --url-exact, --url-endswith, --url-regex, --window (with optional --tab-in-window), --document, or --tab
                  2. --key <prefix>            (8 or more characters, from `safari-browser pdf-cache list`)
                  3. --source webkit-pdfs --file <name>
                It never picks a PDF on its own, not even when only one is cached.
                """
        case .noMatch(let subject, let unreadNote, _, true):
            let unread = unreadNote.map { "\n\(t($0))" } ?? ""
            return """
                No file in the WebKitPDFs folders matches \(t(subject)).\(unread)
                `safari-browser pdf-cache list --source webkit-pdfs` shows them, by folder and name, so that a person can identify one.
                """
        case .noMatch(let subject, let unreadNote, let fromTab, false):
            let unread = unreadNote.map { "\n\(t($0))" } ?? ""
            let tabNote = fromTab
                ? "\nThe tab may be showing a PDF that never reached the cache (a `no-store` response): `safari-browser save-pdf <path>` with the same tab flag saves what the tab holds, without requesting the document."
                : ""
            return """
                No cached PDF matches \(t(subject)).\(unread)
                A tab is matched by its exact URL (fragment removed), and responses stored inside the record \
                itself rather than in a separate body file are not covered.\(tabNote)
                `safari-browser pdf-cache list` shows what is cached so that a person can identify a PDF. A row is \
                not tied to any tab, and the URL it shows has no query: the same URL there can be a different PDF.
                """
        case .ambiguous(let subject, let candidates, let next):
            let lines = candidates.map { "  \($0)" }.joined(separator: "\n")
            let step: String
            switch next {
            case .longerKey:
                step = "Re-run with a longer --key prefix naming one of them."
            case .tabHolds:
                step = "Nothing here says which one the tab displays. `safari-browser save-pdf <path>` with the same tab flag saves what the tab holds; --key <prefix> is for one a person has identified."
            case .folderAndName:
                step = "Re-run with --file <folder>/<name> naming one of them, as shown above."
            }
            return """
                \(t(subject)) matches \(candidates.count) cached PDFs; refusing to choose between them:
                \(lines)
                \(step)
                """
        case .unreadableRecord(let key):
            return "The record for cached PDF '\(t(key))' cannot be read as the 'Version 17' layout, so it cannot be selected."
        case .recordDisagrees(let key):
            return "The record for cached PDF '\(t(key))' does not describe the body file beside it (a different length): Safari was probably writing or replacing it. It is not copied; try again once the page has finished loading."
        case .partialBody(let key):
            return "The cached body for '\(t(key))' holds only a byte range of a resource, not a whole document, so it cannot be copied."
        case .notAPDF(let name):
            return "'\(t(name))' does not start with %PDF-, so it is not copied."
        case .unreadablePDF(let detail):
            return "The copy starts with %PDF- but is not a readable PDF (\(t(detail))); nothing was written."
        case .destinationExists(let path):
            return "\(t(path)) already exists. Pass --force to replace it."
        case .destinationDirectoryMissing(let path):
            return "The destination folder does not exist: \(t(path))"
        case .destinationWriteFailed(let path, let detail):
            return "Could not write \(t(path)): \(t(detail))"
        }
    }
}
