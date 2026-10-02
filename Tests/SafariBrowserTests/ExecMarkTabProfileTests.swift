import Foundation
import XCTest
@testable import SafariBrowser

/// #170 re-review: `markTabIfRequested` resolves the tab six times (read and write when wrapping, read
/// and write when restoring, and in the persist form), each with the exec-level `--profile`. One test
/// pinned only the first read. Here the profile of every window changes after a chosen read or write; a
/// call that forwarded the profile fails to resolve and sends nothing, a call that dropped it finds the
/// window anyway and sends its JavaScript.
final class ExecMarkTabProfileTests: XCTestCase, @unchecked Sendable {
    /// A Safari whose tab title can be read and written, and whose windows change profile on cue.
    private final class TitledSafari: @unchecked Sendable {
        private let lock = NSLock()
        private let fake = ExecSharedTargetTests.Fake()
        private var title = "Page"
        private(set) var reads = 0
        private(set) var writes = 0
        private(set) var renamed = false
        private(set) var javaScriptAfterRename = 0
        var renameAfter: (reads: Int, writes: Int)

        /// `(0, 0)` means the windows are in another profile from the first call.
        init(renameAfter: (reads: Int, writes: Int)) {
            self.renameAfter = renameAfter
            self.renamed = renameAfter.reads == 0 && renameAfter.writes == 0
        }

        func respond(_ script: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            if script.contains("do JavaScript") {
                if renamed { javaScriptAfterRename += 1 }
                if script.contains("document.title = ") {
                    writes += 1
                    // A write that carries the zero-width marker is the wrapping one; the other restores.
                    title = script.contains(MarkerConstants.prefix) ? MarkerConstants.wrap(title: "Page") : "Page"
                } else {
                    reads += 1
                }
                let answer = script.contains("document.title = ") ? "ok" : title
                if reads >= renameAfter.reads, writes >= renameAfter.writes { renamed = true }
                return answer
            }
            let answer = try fake.respond(script)
            // After the cue every window belongs to another profile.
            return renamed ? answer.replacingOccurrences(of: "個人 — ", with: "其他 — ") : answer
        }
    }

    private func run(_ mode: TargetOptions.MarkTabMode, renameAfter: (reads: Int, writes: Int)) async -> (error: Error?, safari: TitledSafari) {
        let safari = TitledSafari(renameAfter: renameAfter)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try safari.respond($0) }) {
                    try await SafariBridge.markTabIfRequested(
                        target: .urlMatch(.contains("w1.example/2")), mode: mode, firstMatch: false, profile: "個人"
                    ) { () async throws -> Void in }
                }
            }
            return (nil, safari)
        } catch { return (error, safari) }
    }

    private func assertStopsAtTheProfile(_ label: String, _ result: (error: Error?, safari: TitledSafari), file: StaticString = #filePath, line: UInt = #line) {
        guard case SafariBrowserError.documentNotFound? = result.error else {
            return XCTFail("\(label): expected documentNotFound once the window left the profile, got \(String(describing: result.error))", file: file, line: line)
        }
        XCTAssertTrue(result.safari.renamed, "\(label): the cue was reached", file: file, line: line)
        XCTAssertEqual(result.safari.javaScriptAfterRename, 0,
                       "\(label): nothing may be sent to a window that is no longer in the profile", file: file, line: line)
    }

    func testTheProfileIsForwardedByEveryCallOfTheMarker() async {
        // From the first call: the very first read of either form.
        assertStopsAtTheProfile("persist, the first read", await run(.persist, renameAfter: (0, 0)))
        assertStopsAtTheProfile("ephemeral, the first read", await run(.ephemeral, renameAfter: (0, 0)))
        // The persist form: read, then write.
        assertStopsAtTheProfile("persist, the write after the read", await run(.persist, renameAfter: (1, 0)))
        // The ephemeral form: wrap (read, write), the operation, restore (read, write).
        assertStopsAtTheProfile("ephemeral, the wrapping write", await run(.ephemeral, renameAfter: (1, 0)))
        assertStopsAtTheProfile("ephemeral, the restoring read", await run(.ephemeral, renameAfter: (1, 1)))
        assertStopsAtTheProfile("ephemeral, the restoring write", await run(.ephemeral, renameAfter: (2, 1)))
    }

    func testTheMarkerIsAppliedAndRemovedInsideTheProfile() async {
        // The control: with the profile unchanged the same calls run to the end.
        let safari = TitledSafari(renameAfter: (Int.max, Int.max))
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try safari.respond($0) }) {
                    try await SafariBridge.markTabIfRequested(
                        target: .urlMatch(.contains("w1.example/2")), mode: .ephemeral, firstMatch: false, profile: "個人"
                    ) { () async throws -> Void in }
                }
            }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(safari.writes, 2, "wrapped, then restored")
        XCTAssertEqual(safari.reads, 2)
    }
}
