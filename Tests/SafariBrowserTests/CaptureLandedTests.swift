import XCTest
@testable import SafariBrowser

/// #99: proving a screenshot actually landed.
///
/// `screencapture` exits 0 when it cannot write the file — measured against a
/// missing directory and against SIP-protected `/System`, both of which gave
/// exit 0, empty stderr, and no file. So the exit code carries no information
/// about whether a screenshot exists, and the file is the only evidence.
final class CaptureLandedTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idd99-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAcceptsAFileWithContent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        XCTAssertNoThrow(try ScreenshotCommand.verifyCaptureLanded(at: file.path))
    }

    func testRejectsAMissingFileAndSaysTheDirectoryIsSuspect() throws {
        let path = "/nonexistent-dir-\(UUID().uuidString)/shot.png"
        XCTAssertThrowsError(try ScreenshotCommand.verifyCaptureLanded(at: path)) { error in
            guard case SafariBrowserError.captureNotWritten(let reported, let reason) = error else {
                return XCTFail("expected captureNotWritten, got \(error)")
            }
            XCTAssertEqual(reported, path, "the path must be echoed — it is usually the typo")
            XCTAssertEqual(reason, .noFile)
        }
    }

    /// A zero-byte file is not a screenshot. Treating it as success moves the
    /// failure downstream, where it surfaces as an unreadable image rather than
    /// as a capture that did not happen.
    func testRejectsAnEmptyFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("empty.png")
        try Data().write(to: file)
        XCTAssertThrowsError(try ScreenshotCommand.verifyCaptureLanded(at: file.path)) { error in
            guard case SafariBrowserError.captureNotWritten(_, let reason) = error else {
                return XCTFail("expected captureNotWritten, got \(error)")
            }
            XCTAssertEqual(reason, .emptyFile,
                           "an empty file and a missing one point at different causes")
        }
    }

    func testMessageExplainsWhyTheExitCodeCouldNotBeTrusted() {
        let text = SafariBrowserError
            .captureNotWritten(path: "/tmp/x.png", reason: .noFile)
            .errorDescription ?? ""
        // Without this the reader assumes the tool swallowed an error, and goes
        // looking in the wrong place for it.
        XCTAssertTrue(text.contains("exits 0"), text)
        XCTAssertTrue(text.contains("/tmp/x.png"), text)
        XCTAssertTrue(text.contains("writable"), text)
    }
}
