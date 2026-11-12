import Foundation
import XCTest
@testable import SafariBrowser

/// #355, the rows of the verify report of 2026-11-12 (gate round 1) that change code or need a test.
final class EnumerationGateRound1Tests: XCTestCase {

    // MARK: row 13 — a windows-changed list says it may succeed on a rerun

    /// The listing note after a miss names the kind of failure. A list rejected because two windows reported
    /// one id is "malformed" too (the spec asks for that word), but the cause is a window raised mid-read, so the
    /// note says the windows changed and that running the command again may help; the shape kinds do not.
    func testTheListingNoteOfAWindowsChangedListSaysToRunAgain() {
        let changed = SafariBrowserError.enumerationFailureNote(
            SafariBrowserError.windowEnumerationCorrupt(reason: "windows 2 and 3 report one id", kind: .windowsChanged))
        XCTAssertTrue(changed.contains("malformed"), changed)
        XCTAssertTrue(changed.contains("the windows changed while it was read"), changed)
        XCTAssertTrue(changed.contains("running the command again may help"), changed)
        XCTAssertFalse(changed.contains("windows 2 and 3"), "no text of the reason: \(changed)")

        for kind in [WindowEnumerationProblem.shape, .windowIDNotInteger] {
            let note = SafariBrowserError.enumerationFailureNote(SafariBrowserError.windowEnumerationCorrupt(reason: "r", kind: kind))
            XCTAssertTrue(note.contains("malformed"), note)
            XCTAssertFalse(note.contains("changed while it was read"), "\(kind): \(note)")
        }
    }

    // MARK: row 8 — the marker note names the missing capability

    private final class Recorder: StepDispatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var commands: [String] { lock.withLock { calls } }
        func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
            lock.withLock { calls.append(cmd) }
            return "x"
        }
    }

    /// A marked script the daemon would run whole, sent to a daemon that does not announce the source form
    /// (`runViaDaemon` returns nil after its fallback line): the script runs step by step, and the note about the
    /// marker lists, among its reasons, the one that holds here.
    func testTheMarkerNoteNamesADaemonWithoutTheCapability() async throws {
        let recorder = Recorder()
        var notes: [String] = []
        try await ExecCommand.parse([]).execute(
            source: ##"[{"cmd":"get url"}]"##, pacingEnabled: false, daemonOptedIn: true,
            viaDaemon: { _, _ in nil },
            note: { notes.append($0) }, environment: ["SAFARI_BROWSER_MARK_TAB": "1"], stepDispatcher: recorder)
        XCTAssertEqual(recorder.commands, ["get url"])
        let marker = try XCTUnwrap(notes.first { $0.contains("tab-ownership marker") }, "\(notes)")
        XCTAssertTrue(marker.contains("the daemon does not announce the source form"), marker)
        XCTAssertTrue(marker.contains("safari-browser daemon stop"), marker)
    }
}
