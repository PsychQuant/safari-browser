import ArgumentParser
import Foundation

/// Read PDFs Safari has already cached (#210).
///
/// A page-level request to a publisher can be judged automated traffic. The
/// copy Safari holds cannot: this command only reads files, so nothing leaves
/// the machine and nothing in Safari is driven. The one thing it asks Safari
/// for is the target tab's URL, and only when a tab flag is given.
///
/// Like `history` and `downloads` this exposes a record of what the user
/// viewed, so `list` carries a default limit and `get` acts only on an
/// explicit selection.
struct PDFCacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf-cache",
        abstract: "List or copy PDFs Safari already cached, without any request (requires Full Disk Access)",
        subcommands: [PDFCacheList.self, PDFCacheGet.self]
    )
}

struct PDFCacheList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List cached PDFs (key, partition, URL without query, size, time)"
    )

    @Option(name: .long, help: "Where to read: cache (default) or webkit-pdfs")
    var source: PDFCacheSource = .cache

    @Option(name: .long, help: "Maximum rows to return (default 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be a positive integer.") }
    }

    func run() throws {
        try run(paths: .live, timeZone: .current)
    }

    func run(paths: PDFCachePaths, timeZone: TimeZone) throws {
        let rendered: PDFCacheFormat.Rendered
        let jsonData: () throws -> Data
        switch source {
        case .cache:
            let scan = try WebKitCacheReader.scan(cacheRoot: paths.cacheRoot)
            if scan.unreadableRecords > 0 {
                LocalDataOutput.writeStderr(
                    "pdf-cache: \(scan.unreadableRecords) cached PDF(s) have a record this command cannot read and are not listed.\n")
            }
            if !scan.partialKeys.isEmpty {
                LocalDataOutput.writeStderr(
                    "pdf-cache: \(scan.partialKeys.count) cached PDF body(ies) hold only a byte range and are not listed.\n")
            }
            rendered = PDFCacheFormat.cacheListing(scan.pdfs, limit: limit, timeZone: timeZone)
            jsonData = { try PDFCacheFormat.cacheListingJSON(scan.pdfs, limit: limit) }
            if scan.pdfs.isEmpty { LocalDataOutput.writeStderr("pdf-cache: no PDF found in the network cache.\n") }
        case .webkitPDFs:
            let listed = try WebKitTemporaryPDFs.scan(temporaryRoot: paths.temporaryRoot)
            rendered = PDFCacheFormat.temporaryListing(listed, limit: limit, timeZone: timeZone)
            jsonData = { try PDFCacheFormat.temporaryListingJSON(listed, limit: limit) }
            if listed.isEmpty { LocalDataOutput.writeStderr("pdf-cache: no PDF found in the WebKitPDFs folders.\n") }
        }
        try LocalDataOutput.emit(json: json, jsonData: jsonData, textRows: rendered.rows, legend: rendered.legend)
    }
}

struct PDFCacheGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Copy one cached PDF to a file; needs an explicit selection and never picks for you",
        discussion: """
            Select exactly one of: a tab flag (--url, --url-exact, --url-endswith, --url-regex, \
            --window [--tab-in-window], --document, --tab), --key <prefix>, or --source webkit-pdfs --file <name>. \
            A tab is matched by its exact URL (fragment removed); no match, or several, stops and lists the candidates.
            """
    )

    @Argument(help: "Where to write the PDF (the folder must exist)")
    var path: String

    @Option(name: .long, help: "Select by the start (8+ hex characters) of a key shown by `pdf-cache list`")
    var key: String?

    @Option(name: .long, help: "Where to read: cache (default) or webkit-pdfs")
    var source: PDFCacheSource = .cache

    @Option(name: .long, help: "With --source webkit-pdfs: the file name to copy")
    var file: String?

    @Flag(name: .long, help: "Replace the destination if it exists")
    var force = false

    @Flag(name: .long, help: "Output as JSON object")
    var json = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        guard !path.isEmpty else { throw ValidationError("The destination path must not be empty.") }
        do {
            _ = try selectionForm()
        } catch let usage as PDFCacheSelection.UsageError {
            throw ValidationError(usage.message)
        } catch {
            // No selection at all is reported by run(), before anything is read.
        }
    }

    func selectionForm() throws -> PDFCacheSelection.Form {
        try PDFCacheSelection.form(hasTab: target.hasExplicitTarget, key: key, file: file, source: source)
    }

    func run() async throws {
        let form = try selectionForm()
        var tabURL: String?
        if case .tab = form {
            tabURL = try await SafariBridge.getCurrentURL(
                target: target.resolve(),
                firstMatch: target.firstMatch,
                warnWriter: TargetOptions.stderrWarnWriter,
                profile: target.resolveProfile()
            )
        }
        let retrieved = try PDFCacheService.retrieve(
            form: form, tabURL: tabURL, paths: .live, destination: path, force: force)
        if json {
            print(String(decoding: try PDFCacheFormat.retrievedJSON(retrieved), as: UTF8.self))
        } else {
            print(PDFCacheFormat.retrievedRow(retrieved))
        }
    }
}
