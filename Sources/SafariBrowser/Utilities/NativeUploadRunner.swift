import Foundation

/// The parent holds its clipboard lease throughout this single bounded child.
enum NativeUploadRunner {
    static func run(_ request: NativeUploadRequest,
                    warnWriter: (@Sendable (String) -> Void)? = nil) async throws {
        try await PerformanceTrace.spanAsync(.fileDialog) {
            let executable = try MCPWorkerContext.executableURL().path
            let arguments = ["__native-upload", try request.encodedArgument(), try MCPWorkerContext.currentImageIdentifier()]
            let writer = FileDialogDiagnostics.writer(warnWriter)
            do {
                _ = try await SafariBridge.runShell(executable, arguments, timeout: request.timeout,
                    stderrWriter: { raw in
                        if let line = FileDialogDiagnostics.trace(raw) { writer(line) }
                    }, importOwnTiming: true)
            } catch SafariBrowserError.subprocessFailed(_, let message) {
                // Keep the established upload sentinel mapping and original error.
                throw SafariBrowserError.appleScriptFailed(message)
            }
        }
    }
}
