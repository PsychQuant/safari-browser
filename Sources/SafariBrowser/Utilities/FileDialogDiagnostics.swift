import Foundation

/// AppleScript `log` writes stderr even when a file operation succeeds.
/// Render one bounded line so filenames and error text cannot inject controls.
enum FileDialogDiagnostics {
    static let renderedLimit = 4096

    static func trace(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let prefix = "file dialog trace: "
        return prefix + TerminalText.escaped(raw, limit: renderedLimit - prefix.unicodeScalars.count - 1) + "\n"
    }

    static func writer(_ custom: (@Sendable (String) -> Void)?) -> @Sendable (String) -> Void {
        if let custom { return custom }
        if let context = DaemonRequestContext.current {
            return { context.emit($0) }
        }
        return { FileHandle.standardError.write(Data($0.utf8)) }
    }
}
