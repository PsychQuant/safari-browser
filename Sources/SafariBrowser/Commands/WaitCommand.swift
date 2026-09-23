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

    static func nanoseconds(forMilliseconds milliseconds: Int) throws -> UInt64 {
        guard milliseconds >= 0 else {
            throw ValidationError("Milliseconds must be non-negative, got \(milliseconds)")
        }
        let converted = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        guard !converted.overflow else {
            throw ValidationError("Milliseconds exceed the maximum representable wait of \(UInt64.max / 1_000_000), got \(milliseconds)")
        }
        return converted.partialValue
    }

    func run() async throws {
        if let forUrl {
            try await waitForURL(pattern: forUrl)
        } else if let js {
            try await waitForJS(expression: js)
        } else if let milliseconds {
            let duration = try Self.nanoseconds(forMilliseconds: milliseconds)
            try await Task.sleep(nanoseconds: duration)
        }
    }

    /// #168: resolve the target once, before the first poll. Re-resolving on
    /// every 500 ms poll cost one full window/tab enumeration per poll for a
    /// `--url` target, and it defeated the command's purpose: waiting for a
    /// navigation away from the URL the target was named by failed on the next
    /// poll, because the old URL no longer matched anything. Anchored the same
    /// way `js` is (#180): a `--url` / `--document` target is pinned to its tab
    /// by window id, and the default target / `--window N` to the window's
    /// current tab. The deadline starts before resolution, so resolution stays
    /// inside the caller's timeout. The multi-match warning (#59) fires once,
    /// at this single resolution.
    private func resolveOnce() async throws -> (
        original: SafariBridge.TargetDocument, anchored: SafariBridge.TargetDocument, firstMatch: Bool
    ) {
        let (initial, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let anchored = try await SafariBridge.resolveToAnchoredTarget(
            initial, firstMatch: firstMatch, warnWriter: warnWriter, profile: target.resolveProfile())
        return (initial, anchored, firstMatch)
    }

    private func waitForURL(pattern: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        let (original, anchored, firstMatch) = try await resolveOnce()
        while Date() < deadline {
            let currentURL: String
            do {
                currentURL = try await SafariBridge.getCurrentURL(
                    target: anchored, firstMatch: firstMatch, warnWriter: nil,
                    profile: target.resolveProfile())
            } catch let error as SafariBrowserError {
                throw JSCommand.anchoredFailure(error, original: original, anchored: anchored)
            }
            if currentURL.contains(pattern) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }

    private func waitForJS(expression: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        let (original, anchored, firstMatch) = try await resolveOnce()
        while Date() < deadline {
            let result: String
            do {
                result = try await SafariBridge.doJavaScript(
                    "!!(\(expression)) ? 'true' : ''",
                    target: anchored, firstMatch: firstMatch, warnWriter: nil,
                    profile: target.resolveProfile())
            } catch let error as SafariBrowserError {
                throw JSCommand.anchoredFailure(error, original: original, anchored: anchored)
            }
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }
}
