import Foundation

/// Text and JSON presentation for `pdf-cache` (#210). Every URL is redacted
/// (`PDFCacheURL`) and every external string is kept inside its own field
/// (`LocalDataOutput.sanitizeTextField`).
enum PDFCacheFormat {
    struct Rendered {
        let rows: [String]
        let legend: String
    }

    static func timestamp(_ date: Date?, timeZone: TimeZone) -> String {
        guard let date else { return "(no date)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func iso(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func encode(_ payload: Any, emptyAs empty: String = "[]") throws -> Data {
        if let array = payload as? [Any], array.isEmpty { return Data(empty.utf8) }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func field(_ text: String) -> String { LocalDataOutput.sanitizeTextField(text) }
    private static func keyPrefix(_ key: String) -> String { String(key.prefix(12)) }

    // MARK: - Network cache

    static func candidateLine(_ pdf: WebKitCachedPDF, timeZone: TimeZone = .current) -> String {
        [field(keyPrefix(pdf.key)),
         pdf.partition.isEmpty ? "-" : field(PDFCacheURL.redact(pdf.partition).display),
         field(PDFCacheURL.redact(pdf.requestURL).display),
         "\(pdf.size) B",
         timestamp(pdf.modified, timeZone: timeZone)].joined(separator: "  ")
    }

    static func cacheListing(_ pdfs: [WebKitCachedPDF], limit: Int, timeZone: TimeZone) -> Rendered {
        Rendered(
            rows: pdfs.prefix(limit).enumerated().map { index, pdf in
                "[\(index + 1)]  \(timestamp(pdf.modified, timeZone: timeZone))  \(field(keyPrefix(pdf.key)))  "
                    + "\(pdf.partition.isEmpty ? "-" : field(PDFCacheURL.redact(pdf.partition).display))  "
                    + "\(field(PDFCacheURL.redact(pdf.requestURL).display))  \(pdf.size) B"
            },
            legend: "pdf-cache: [N]  local-time  key  partition  url (query and fragment removed)  size  "
                + "(default limit 50; use --limit; select one with `pdf-cache get <path> --key <prefix>`)")
    }

    static func cacheListingJSON(_ pdfs: [WebKitCachedPDF], limit: Int) throws -> Data {
        try encode(pdfs.prefix(limit).map { pdf -> [String: Any] in
            let redacted = PDFCacheURL.redact(pdf.requestURL)
            return [
                "key": pdf.key,
                "partition": PDFCacheURL.redact(pdf.partition).display,
                "url": redacted.display,
                "has_query": redacted.hadQuery,
                "size": pdf.size,
                "modified": iso(pdf.modified),
            ]
        })
    }

    // MARK: - WebKitPDFs

    static func candidateLine(_ pdf: TemporaryPDF, timeZone: TimeZone = .current) -> String {
        "\(field(pdf.folder))/\(field(pdf.name))  \(pdf.size) B  \(timestamp(pdf.date, timeZone: timeZone))"
    }

    static func temporaryListing(_ pdfs: [TemporaryPDF], limit: Int, timeZone: TimeZone) -> Rendered {
        Rendered(
            rows: pdfs.prefix(limit).enumerated().map { index, pdf in
                "[\(index + 1)]  \(timestamp(pdf.date, timeZone: timeZone))  \(field(pdf.name))  \(field(pdf.folder))  \(pdf.size) B"
            },
            legend: "pdf-cache (webkit-pdfs): [N]  local-time  file  folder  size  "
                + "(default limit 50; use --limit; select one with `pdf-cache get <path> --source webkit-pdfs --file <name>`)")
    }

    static func temporaryListingJSON(_ pdfs: [TemporaryPDF], limit: Int) throws -> Data {
        try encode(pdfs.prefix(limit).map { pdf -> [String: Any] in
            ["file": pdf.name, "folder": pdf.folder, "size": pdf.size, "modified": iso(pdf.date)]
        })
    }

    // MARK: - get

    static func retrievedRow(_ retrieved: PDFCacheService.Retrieved) -> String {
        let result = retrieved.result
        let origin: String
        switch retrieved.origin {
        case .networkCache(let key, let url): origin = "cache \(field(keyPrefix(key)))  \(field(url))"
        case .temporaryPDFs(let folder, let name): origin = "webkit-pdfs \(field(folder))/\(field(name))"
        }
        return "\(field(result.path))  \(result.size) B  \(result.pages) page(s)  from \(origin)"
    }

    static func retrievedJSON(_ retrieved: PDFCacheService.Retrieved) throws -> Data {
        var object: [String: Any] = [
            "path": retrieved.result.path, "size": retrieved.result.size, "pages": retrieved.result.pages,
        ]
        switch retrieved.origin {
        case .networkCache(let key, let url):
            object["source"] = "cache"; object["key"] = key; object["url"] = url
        case .temporaryPDFs(let folder, let name):
            object["source"] = "webkit-pdfs"; object["folder"] = folder; object["file"] = name
        }
        return try encode(object)
    }
}
