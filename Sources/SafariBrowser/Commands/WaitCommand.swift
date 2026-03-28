import ArgumentParser
import Foundation

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a duration, URL pattern, or JS condition"
    )

    @Argument(help: "Milliseconds to wait (when no --url or --js is used)")
    var milliseconds: Int?

    @Option(name: .long, help: "Wait until the URL contains this pattern")
    var url: String?

    @Option(name: .long, help: "Wait until this JS expression is truthy")
    var js: String?

    @Option(name: .long, help: "Timeout in milliseconds (default: 30000)")
    var timeout: Int = 30000

    func validate() throws {
        if milliseconds == nil && url == nil && js == nil {
            throw ValidationError("Provide milliseconds, --url, or --js")
        }
    }

    func run() async throws {
        if let url {
            try await waitForURL(pattern: url)
        } else if let js {
            try await waitForJS(expression: js)
        } else if let milliseconds {
            guard milliseconds >= 0 else {
                throw ValidationError("Milliseconds must be non-negative, got \(milliseconds)")
            }
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    private func waitForURL(pattern: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        while Date() < deadline {
            let currentURL = try await SafariBridge.getCurrentURL()
            if currentURL.contains(pattern) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }

    private func waitForJS(expression: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        while Date() < deadline {
            let result = try await SafariBridge.doJavaScript(
                "!!(\(expression)) ? 'true' : ''"
            )
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }
}
