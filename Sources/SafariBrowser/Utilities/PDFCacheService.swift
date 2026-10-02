import Foundation

/// Where `pdf-cache` reads. Injectable so tests never touch the real cache.
struct PDFCachePaths: Equatable {
    let cacheRoot: URL
    let temporaryRoot: URL

    static var live: PDFCachePaths {
        PDFCachePaths(cacheRoot: WebKitCacheReader.defaultCacheRoot, temporaryRoot: WebKitTemporaryPDFs.defaultRoot)
    }
}

/// Selects one PDF and copies it (#210). Pure orchestration: no printing, no
/// Safari access — the caller supplies the tab's URL when the form needs it.
enum PDFCacheService {
    enum Origin: Equatable {
        case networkCache(key: String, displayURL: String)
        case temporaryPDFs(folder: String, name: String)
    }

    struct Retrieved: Equatable {
        let result: PDFCacheOutput.Result
        let origin: Origin
    }

    static func retrieve(
        form: PDFCacheSelection.Form, tabURL: String?, paths: PDFCachePaths, destination: String, force: Bool
    ) throws -> Retrieved {
        switch form {
        case .tab:
            guard let tabURL else { throw SafariBrowserError.pdfCache(.selectionRequired) }
            let scan = try WebKitCacheReader.scan(cacheRoot: paths.cacheRoot)
            return try copy(
                try PDFCacheSelection.select(tabURL: tabURL, scan: scan), destination: destination, force: force,
                protecting: paths.cacheRoot)
        case .key(let prefix):
            let scan = try WebKitCacheReader.scan(cacheRoot: paths.cacheRoot)
            return try copy(
                try PDFCacheSelection.select(keyPrefix: prefix, scan: scan), destination: destination, force: force,
                protecting: paths.cacheRoot)
        case .file(let name):
            let listed = try WebKitTemporaryPDFs.scan(temporaryRoot: paths.temporaryRoot)
            let chosen = try PDFCacheSelection.select(fileName: name, from: listed)
            let result = try PDFCacheOutput.copyVerified(
                from: chosen.url, to: destination, force: force,
                protectedFolders: [paths.temporaryRoot.appendingPathComponent(chosen.folder, isDirectory: true), paths.cacheRoot])
            return Retrieved(result: result, origin: .temporaryPDFs(folder: chosen.folder, name: chosen.name))
        }
    }

    private static func copy(_ pdf: WebKitCachedPDF, destination: String, force: Bool, protecting cacheRoot: URL) throws -> Retrieved {
        let result = try PDFCacheOutput.copyVerified(
            from: pdf.bodyURL, to: destination, force: force, protectedFolders: [cacheRoot],
            expectedSize: pdf.size, expectedKey: pdf.key)
        return Retrieved(
            result: result,
            origin: .networkCache(key: pdf.key, displayURL: PDFCacheURL.redact(pdf.requestURL).display))
    }
}
