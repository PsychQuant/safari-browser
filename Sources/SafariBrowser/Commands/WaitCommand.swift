import ArgumentParser
import Foundation

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a duration, URL pattern, or JS condition"
    )

    @Argument(help: "Milliseconds to wait (when no --for-url or --js is used)")
    var milliseconds: Int?

    // #23: renamed from --url to --for-url. The old `--url` now belongs to
    // TargetOptions and means "target the document whose URL contains <x>",
    // not "wait until the URL contains <x>". Breaking change — see CHANGELOG.
    @Option(name: .long, help: "Wait until the URL contains this pattern")
    var forUrl: String?

    @Option(name: .long, help: "Wait until this JS expression is truthy")
    var js: String?

    @Option(name: .long, help: "Timeout in milliseconds (default: 30000)")
    var timeout: Int = 30000

    @OptionGroup var target: TargetOptions

    func validate() throws {
        if milliseconds == nil && forUrl == nil && js == nil {
            // #23 verify R1 finding: detect the rename trap. Users running
            // old `wait --url <pattern>` syntax parse --url as a targeting
            // flag (not a wait predicate) and hit this validate() with a
            // cryptic "Provide milliseconds..." error. If target.url is
            // the ONLY thing they set, they almost certainly meant the old
            // wait-for-URL semantic — point them at --for-url explicitly.
            if target.url != nil && target.window == nil && target.tab == nil && target.document == nil {
                throw ValidationError(
                    "`wait --url <pattern>` was renamed to `wait --for-url <pattern>` in #23 — `--url` is now a global targeting flag. Retry as `safari-browser wait --for-url \"\(target.url!)\"` (see CHANGELOG)."
                )
            }
            throw ValidationError("Provide milliseconds, --for-url, or --js")
        }
    }

    func run() async throws {
        if let forUrl {
            try await waitForURL(pattern: forUrl)
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
        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        while Date() < deadline {
            let currentURL = try await SafariBridge.getCurrentURL(target: resolvedTarget)
            if currentURL.contains(pattern) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }

    private func waitForJS(expression: String) async throws {
        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        while Date() < deadline {
            let result = try await SafariBridge.doJavaScript(
                "!!(\(expression)) ? 'true' : ''",
                target: resolvedTarget
            )
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }
}
