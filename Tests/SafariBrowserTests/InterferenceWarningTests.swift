import AppKit
import XCTest
@testable import SafariBrowser

/// Executes the real native-upload lifecycle against a private pasteboard.
/// Safari itself is represented only by the subprocess closure; GUI coverage is separate.
@MainActor
final class InterferenceWarningTests: XCTestCase {
    private func fixture() throws -> (URL, NSPasteboard) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let file = dir.appendingPathComponent("檔案 ' quoted.txt")
        try Data("owned".utf8).write(to: file)
        let board = NSPasteboard(name: .init("idd-upload-test-" + UUID().uuidString))
        board.setString("previous clipboard", forType: .string)
        return (file, board)
    }

    func testWarningPrecedesOneCombinedNativeOperation() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var events: [String] = []
        try await UploadCommand.performNativeUpload(fileURL: file, selector: "input[type=file]", window: 2, timeout: 4, pasteboard: board, windowID: 8128,
            warn: { text in
                events.append("warn")
                XCTAssertEqual(board.string(forType: .string), "previous clipboard", "warn before clipboard interference")
                XCTAssertEqual(text, UploadCommand.nativeInterferenceWarning)
            }, runRequest: { request in
                let script = request.makeScript()
                events.append("script")
                let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
                XCTAssertEqual(urls, [file.resolvingSymlinksInPath()])
                XCTAssertTrue(script.contains("input[type=file]"))
            })
        XCTAssertEqual(events, ["warn", "script"])
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testNativeUploadDoesNotGenerateHIDNavigation() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var calls = 0
        try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 4, pasteboard: board, windowID: 8128,
            warn: { _ in }, runRequest: { request in
                let script = request.makeScript()
                calls += 1
                XCTAssertFalse(script.contains("keystroke"))
                XCTAssertFalse(script.contains("key code"))
                XCTAssertFalse(script.contains("Go to Folder"))
                XCTAssertTrue(script.contains("AXPress"))
            })
        XCTAssertEqual(calls, 1)
    }

    func testWarningNamesTheInterferenceType() {
        let warning = UploadCommand.nativeInterferenceWarning.lowercased()
        XCTAssertTrue(warning.contains("file dialog"))
        XCTAssertTrue(warning.contains("clipboard"))
        XCTAssertTrue(warning.contains("focus"))
        XCTAssertFalse(warning.contains("controlling keyboard"))
        XCTAssertTrue(warning.hasSuffix("\n"))
    }

    func testFailureRestoresClipboardWithoutRetry() async throws {
        enum Failure: Error { case timeout }
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var calls = 0
        do {
            try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 4, pasteboard: board, windowID: 8128,
                warn: { _ in }, runRequest: { _ in calls += 1; throw Failure.timeout })
            XCTFail("runner failure must propagate")
        } catch Failure.timeout { }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testNewerClipboardIsPreservedAfterRunnerFailure() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var warnings: [String] = []
        do {
            try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 4, pasteboard: board, windowID: 8128,
                warn: { warnings.append($0) }, runRequest: { _ in
                    board.clearContents(); board.setString("new copy", forType: .string)
                    throw CancellationError()
                })
            XCTFail("cancellation must propagate")
        } catch is CancellationError { }
        XCTAssertEqual(board.string(forType: .string), "new copy")
        XCTAssertTrue(warnings.dropFirst().contains { $0.lowercased().contains("preserv") })
    }

    func testMissingFileDoesNotWarnOrInvokeNativeRunner() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: file)
        do {
            try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 4, pasteboard: board, windowID: 8128,
                warn: { _ in XCTFail("missing file must fail before interference") }, runRequest: { _ in XCTFail("unexpected native operation") })
            XCTFail("missing file must fail")
        } catch { }
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testTimeoutContainingScriptMarkerRemainsTimeout() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        do {
            try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 3, pasteboard: board, windowID: 8128,
                warn: { _ in }, runRequest: { _ in
                    throw SafariBrowserError.processTimedOut(command: "osascript -e error SB_UPLOAD_INPUT_NOT_FOUND", seconds: 3)
                })
            XCTFail("expected timeout")
        } catch let error as SafariBrowserError {
            guard case .processTimedOut(let command, let seconds) = error else { return XCTFail("expected timeout, got \(error)") }
            XCTAssertEqual(seconds, 3)
            XCTAssertEqual(command, "native file URL upload")
        }
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testOnlyActualMissingInputErrorMapsToElementNotFound() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for message in ["10:20: execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)", "syntax error near SB_UPLOAD_INPUT_NOT_FOUND"] {
            do {
                try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: nil, timeout: 3, pasteboard: board, windowID: 8128,
                    warn: { _ in }, runRequest: { _ in throw SafariBrowserError.appleScriptFailed(message) })
                XCTFail("expected failure")
            } catch let error as SafariBrowserError {
                if message.contains("execution error") {
                    guard case .elementNotFound("#file") = error else { return XCTFail("missing input must retain typed error") }
                } else {
                    guard case .appleScriptFailed(message) = error else { return XCTFail("must preserve syntax failure, got \(error)") }
                }
            }
        }
    }

    func testOverlappingUploadDoesNotPrepareOrSwitchTarget() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = try FileURLClipboard(fileURL: file, pasteboard: board)
        var switched = false
        var ran = false
        do {
            try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: 2, timeout: 4, pasteboard: board, windowID: 8128,
                prepareTarget: { switched = true }, warn: { _ in }, runRequest: { _ in ran = true })
            XCTFail("overlap must fail")
        } catch FileURLClipboard.ClipboardError.overlappingLease { }
        XCTAssertFalse(switched, "a refused second upload must not change the first upload's target")
        XCTAssertFalse(ran)
        XCTAssertEqual(board.changeCount, first.ownedChangeCount)
        XCTAssertEqual(try first.restore(), .restored)
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testStableWindowAndTabArePassedToNativeScript() async throws {
        let (file, board) = try fixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var prepared = false
        try await UploadCommand.performNativeUpload(fileURL: file, selector: "#file", window: 2, timeout: 4, pasteboard: board,
            windowID: 8128, tabIndex: 3, prepareTarget: {
                prepared = true
                XCTAssertNotNil(board.string(forType: .fileURL), "exclusion and clipboard lease must precede target mutation")
            }, warn: { _ in }, runRequest: { request in
                let script = request.makeScript()
                XCTAssertTrue(prepared)
                XCTAssertTrue(script.contains("set uploadWindowID to id of window id 8128"))
                XCTAssertTrue(script.contains("if uploadTabIndex is not 3"))
            })
    }

    // MARK: - Routing: truth table and short-circuit

    /// All eight combinations. The earlier version tested four and left the
    /// flag-plus-grant cases open, so an implementation that inverted on
    /// `native && granted` would have passed.
    func testRoutingTruthTableIsComplete() {
        let cases: [(native: Bool, allowHid: Bool, granted: Bool, wantsNative: Bool, why: String)] = [
            (false, false, false, false, "no flag, no grant → the non-interfering JS path"),
            (false, false, true,  true,  "no flag, grant present → the #104 exemption"),
            (false, true,  false, true,  "--allow-hid alone forces native"),
            (false, true,  true,  true,  "--allow-hid with a grant is still native"),
            (true,  false, false, true,  "--native alone forces native"),
            (true,  false, true,  true,  "--native with a grant is still native"),
            (true,  true,  false, true,  "both flags, no grant → native"),
            (true,  true,  true,  true,  "both flags and a grant → native"),
        ]
        for c in cases {
            XCTAssertEqual(
                UploadCommand.resolveNativeRouting(
                    native: c.native, allowHid: c.allowHid, accessibilityProbe: { c.granted }),
                c.wantsNative,
                "native=\(c.native) allowHid=\(c.allowHid) granted=\(c.granted): \(c.why)")
        }
    }

    /// An explicit flag decides on its own, so the TCC permission API must not
    /// be consulted at all. Folding the probe into an argument list once made it
    /// eager — same truth table, different number of system calls.
    func testExplicitFlagShortCircuitsThePermissionProbe() {
        for (native, allowHid) in [(true, false), (false, true), (true, true)] {
            var probes = 0
            _ = UploadCommand.resolveNativeRouting(
                native: native, allowHid: allowHid,
                accessibilityProbe: { probes += 1; return false })
            XCTAssertEqual(probes, 0,
                           "native=\(native) allowHid=\(allowHid): the flag already decided")
        }
    }

    func testProbeIsConsultedExactlyOnceWhenNoFlagIsGiven() {
        var probes = 0
        _ = UploadCommand.resolveNativeRouting(
            native: false, allowHid: false,
            accessibilityProbe: { probes += 1; return true })
        XCTAssertEqual(probes, 1, "the grant decides the flagless case, and one check is enough")
    }
}
