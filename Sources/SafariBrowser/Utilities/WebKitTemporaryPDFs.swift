import Foundation
import Darwin

/// A PDF inside one of Safari's `WebKitPDFs-*` temporary folders (#210).
struct TemporaryPDF: Equatable {
    let folder: String
    let name: String
    let url: URL
    let size: Int64
    /// Birth time, falling back to the modification time.
    let date: Date?
}

/// Reads the `WebKitPDFs-*` folders under the Safari container's `tmp`.
///
/// Those folders appear after a person presses "Open with Preview" in
/// Safari's PDF viewer (one observation, not a controlled experiment), so this
/// source is opt-in. This type only lists what is already there: it creates
/// nothing and drives nothing to make anything appear.
enum WebKitTemporaryPDFs {
    static let folderPrefix = "WebKitPDFs-"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/tmp", isDirectory: true)
    }

    /// Newest first. A missing root is an empty result: it is only a folder of
    /// temporaries, not the layout this command depends on.
    static func scan(
        temporaryRoot: URL = defaultRoot,
        reader: WebKitCacheFileReading = POSIXFilePrefixReader()
    ) throws -> [TemporaryPDF] {
        guard let folders = try WebKitCacheReader.listDirectoryIfPresent(temporaryRoot) else { return [] }
        var found: [TemporaryPDF] = []
        for folder in folders where folder.hasPrefix(folderPrefix) {
            let folderURL = temporaryRoot.appendingPathComponent(folder, isDirectory: true)
            guard let names = try WebKitCacheReader.listDirectoryIfPresent(folderURL) else { continue }
            for name in names {
                let url = folderURL.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]),
                    values.isRegularFile == true
                else { continue }
                do {
                    guard try reader.readPrefix(at: url, maxBytes: WebKitCacheReader.pdfMagic.count) == WebKitCacheReader.pdfMagic else { continue }
                } catch SafariBrowserError.safariDataFileNotFound {
                    continue
                }
                found.append(TemporaryPDF(
                    folder: folder, name: name, url: url, size: Int64(values.fileSize ?? 0),
                    date: values.creationDate ?? values.contentModificationDate))
            }
        }
        return found.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return "\(lhs.folder)/\(lhs.name)" < "\(rhs.folder)/\(rhs.name)"
            }
        }
    }
}
