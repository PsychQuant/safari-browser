import XCTest
import ArgumentParser
@testable import SafariBrowser

final class CommandParsingTests: XCTestCase {

    // MARK: - OpenCommand

    func testOpenCommand_basicURL() throws {
        let command = try OpenCommand.parse(["https://example.com"])
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertFalse(command.newTab)
        XCTAssertFalse(command.newWindow)
    }

    func testOpenCommand_newTab() throws {
        let command = try OpenCommand.parse(["https://example.com", "--new-tab"])
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertTrue(command.newTab)
        XCTAssertFalse(command.newWindow)
    }

    // MARK: - JSCommand

    func testJSCommand_fileOption() throws {
        let command = try JSCommand.parseAsRoot(["--file", "test.js"])
        XCTAssertTrue(command is JSCommand)
        let jsCommand = command as! JSCommand
        XCTAssertEqual(jsCommand.file, "test.js")
    }

    // MARK: - WaitCommand

    func testWaitCommand_forUrlAndTimeout() throws {
        // #23: --url was renamed to --for-url to avoid collision with
        // TargetOptions.url (which now means "target the document whose URL
        // contains this substring").
        let command = try WaitCommand.parse(["--for-url", "dashboard", "--timeout", "5000"])
        XCTAssertEqual(command.forUrl, "dashboard")
        XCTAssertEqual(command.timeout, 5000)
    }

    func testWaitCommand_milliseconds() throws {
        let command = try WaitCommand.parse(["1000"])
        XCTAssertEqual(command.milliseconds, 1000)
    }

    func testWaitCommand_urlIsNowTargetingFlag() throws {
        // #23: --url is now inherited from TargetOptions and targets the
        // document whose URL contains this substring — NOT the pattern
        // to wait for.
        let command = try WaitCommand.parse(["--for-url", "dashboard", "--url", "plaud"])
        XCTAssertEqual(command.forUrl, "dashboard")
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    func testWaitCommand_oldUrlFlagRejectedWithRenameHint() {
        // #23 verify R1: old `wait --url <pattern>` syntax parses --url
        // as a targeting flag. validate() detects the rename trap and
        // throws a helpful error pointing at --for-url, not the cryptic
        // "Provide milliseconds..." message that assert-locked the bad
        // UX before the round 1 fix.
        XCTAssertThrowsError(try WaitCommand.parse(["--url", "plaud"]).validate()) { error in
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("--for-url"),
                "Expected rename hint mentioning --for-url, got: \(description)"
            )
        }
    }

    func testWaitCommand_missingConditionWithNonUrlTarget() {
        // --document / --window / --tab as the only flag is NOT the
        // rename trap — fall through to the generic error.
        XCTAssertThrowsError(try WaitCommand.parse(["--document", "2"]).validate()) { error in
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("Provide milliseconds"),
                "Expected generic error, got: \(description)"
            )
        }
    }

    func testWaitCommand_jsWithTarget() throws {
        let command = try WaitCommand.parse(["--js", "ready", "--document", "2"])
        XCTAssertEqual(command.js, "ready")
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    // MARK: - SnapshotCommand

    func testSnapshotCommand_defaults() throws {
        let command = try SnapshotCommand.parse([])
        XCTAssertFalse(command.page)
        XCTAssertFalse(command.compact)
        XCTAssertFalse(command.json)
        XCTAssertNil(command.selector)
        XCTAssertNil(command.depth)
    }

    func testSnapshotCommand_pageFlag() throws {
        let command = try SnapshotCommand.parse(["--page"])
        XCTAssertTrue(command.page)
        XCTAssertFalse(command.compact)
        XCTAssertFalse(command.json)
    }

    func testSnapshotCommand_pageWithJson() throws {
        let command = try SnapshotCommand.parse(["--page", "--json"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.json)
    }

    func testSnapshotCommand_pageWithScope() throws {
        let command = try SnapshotCommand.parse(["--page", "-s", "main"])
        XCTAssertTrue(command.page)
        XCTAssertEqual(command.selector, "main")
    }

    func testSnapshotCommand_pageWithCompact() throws {
        let command = try SnapshotCommand.parse(["--page", "-c"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.compact)
    }

    func testSnapshotCommand_pageWithAllFlags() throws {
        let command = try SnapshotCommand.parse(["--page", "--json", "-c", "-s", "form", "-d", "5"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.json)
        XCTAssertTrue(command.compact)
        XCTAssertEqual(command.selector, "form")
        XCTAssertEqual(command.depth, 5)
    }

    func testSnapshotCommand_interactiveDefaultUnchanged() throws {
        // Without --page, behavior should be identical to before
        let command = try SnapshotCommand.parse(["-c", "--json"])
        XCTAssertFalse(command.page)
        XCTAssertTrue(command.compact)
        XCTAssertTrue(command.json)
    }

    // MARK: - UploadCommand (#14)

    func testUploadCommand_defaultIsNative() throws {
        // Default (no flags) should use native file dialog
        let command = try UploadCommand.parse(["input", "/tmp/test.txt"])
        XCTAssertFalse(command.js)
        XCTAssertFalse(command.native)
        XCTAssertFalse(command.allowHid)
        XCTAssertEqual(command.timeout, 60.0)
    }

    func testUploadCommand_customTimeout() throws {
        let command = try UploadCommand.parse(["--timeout", "120", "input", "/tmp/test.txt"])
        XCTAssertEqual(command.timeout, 120.0)
    }

    func testUploadCommand_jsFlag() throws {
        let command = try UploadCommand.parse(["--js", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.js)
    }

    func testUploadCommand_nativeBackwardCompat() throws {
        // --native still parses (backward compat), same as default
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.native)
        XCTAssertFalse(command.js)
    }

    func testUploadCommand_allowHidBackwardCompat() throws {
        // --allow-hid still parses (backward compat)
        let command = try UploadCommand.parse(["--allow-hid", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.allowHid)
        XCTAssertFalse(command.js)
    }

    // MARK: - TargetOptions (#17/#18/#21)

    func testTargetOptions_defaultIsFrontWindow() throws {
        let options = try TargetOptions.parse([])
        XCTAssertNil(options.url)
        XCTAssertNil(options.window)
        XCTAssertNil(options.tab)
        XCTAssertNil(options.document)
        XCTAssertEqual(options.resolve(), .frontWindow)
    }

    func testTargetOptions_urlFlag() throws {
        let options = try TargetOptions.parse(["--url", "plaud"])
        XCTAssertEqual(options.url, "plaud")
        XCTAssertEqual(options.resolve(), .urlContains("plaud"))
    }

    func testTargetOptions_windowFlag() throws {
        let options = try TargetOptions.parse(["--window", "2"])
        XCTAssertEqual(options.window, 2)
        XCTAssertEqual(options.resolve(), .windowIndex(2))
    }

    func testTargetOptions_tabFlag() throws {
        // --tab is an alias for --document; both resolve to documentIndex
        let options = try TargetOptions.parse(["--tab", "3"])
        XCTAssertEqual(options.tab, 3)
        XCTAssertEqual(options.resolve(), .documentIndex(3))
    }

    func testTargetOptions_documentFlag() throws {
        let options = try TargetOptions.parse(["--document", "1"])
        XCTAssertEqual(options.document, 1)
        XCTAssertEqual(options.resolve(), .documentIndex(1))
    }

    func testTargetOptions_mutuallyExclusiveFlagsRejected() {
        XCTAssertThrowsError(
            try TargetOptions.parse(["--url", "plaud", "--window", "2"])
        )
    }

    func testTargetOptions_urlAndDocumentMutuallyExclusive() {
        XCTAssertThrowsError(
            try TargetOptions.parse(["--url", "plaud", "--document", "2"])
        )
    }

    func testTargetOptions_tabAndDocumentMutuallyExclusive() {
        XCTAssertThrowsError(
            try TargetOptions.parse(["--tab", "1", "--document", "2"])
        )
    }

    // MARK: - DocumentsCommand (#17/#18/#21)

    func testDocumentsCommand_defaultIsText() throws {
        let command = try DocumentsCommand.parse([])
        XCTAssertFalse(command.json)
    }

    func testDocumentsCommand_jsonFlag() throws {
        let command = try DocumentsCommand.parse(["--json"])
        XCTAssertTrue(command.json)
    }

    // MARK: - UploadCommand target wiring (#23)

    func testUploadCommand_jsModeAcceptsUrlTarget() throws {
        let command = try UploadCommand.parse(["--js", "input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertTrue(command.js)
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    func testUploadCommand_jsModeAcceptsDocumentTarget() throws {
        let command = try UploadCommand.parse(["--js", "input", "/tmp/test.txt", "--document", "2"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testUploadCommand_nativeModeAcceptsWindowTarget() throws {
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--window", "2"])
        XCTAssertTrue(command.native)
        XCTAssertEqual(command.target.resolve(), .windowIndex(2))
    }

    func testUploadCommand_nativeModeRejectsUrlTarget() {
        // validate() runs during parse() — the mutually-exclusive check
        // fails at parse-time rather than at run-time.
        XCTAssertThrowsError(
            try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--url", "plaud"])
        )
    }

    func testUploadCommand_nativeModeRejectsTabTarget() {
        XCTAssertThrowsError(
            try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--tab", "2"])
        )
    }

    func testUploadCommand_nativeModeRejectsDocumentTarget() {
        XCTAssertThrowsError(
            try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--document", "2"])
        )
    }

    func testUploadCommand_allowHidRejectsUrlTarget() {
        // --allow-hid is a legacy alias for --native; same restrictions apply.
        XCTAssertThrowsError(
            try UploadCommand.parse(["--allow-hid", "input", "/tmp/test.txt", "--url", "plaud"])
        )
    }

    func testUploadCommand_smartDefaultAcceptsUrlTarget() throws {
        // Without explicit --native or --js, the smart default logic
        // picks at runtime. Parse-time validation cannot know the mode
        // in advance, so --url is accepted and the runtime path decides.
        let command = try UploadCommand.parse(["input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    // MARK: - WindowOnlyTargetOptions (#23)

    func testWindowOnlyTargetOptions_defaultIsNil() throws {
        let options = try WindowOnlyTargetOptions.parse([])
        XCTAssertNil(options.window)
    }

    func testWindowOnlyTargetOptions_windowFlag() throws {
        let options = try WindowOnlyTargetOptions.parse(["--window", "2"])
        XCTAssertEqual(options.window, 2)
    }

    func testWindowOnlyTargetOptions_rejectsZeroWindow() {
        XCTAssertThrowsError(
            try WindowOnlyTargetOptions.parse(["--window", "0"])
        )
    }

    func testWindowOnlyTargetOptions_rejectsNegativeWindow() {
        XCTAssertThrowsError(
            try WindowOnlyTargetOptions.parse(["--window", "-1"])
        )
    }

    // MARK: - CloseCommand target wiring (#23)

    func testCloseCommand_defaultsNoTarget() throws {
        let command = try CloseCommand.parse([])
        XCTAssertNil(command.windowTarget.window)
    }

    func testCloseCommand_acceptsWindowFlag() throws {
        let command = try CloseCommand.parse(["--window", "2"])
        XCTAssertEqual(command.windowTarget.window, 2)
    }

    // MARK: - ScreenshotCommand target wiring (#23)

    func testScreenshotCommand_defaultsNoTarget() throws {
        let command = try ScreenshotCommand.parse([])
        XCTAssertNil(command.windowTarget.window)
    }

    func testScreenshotCommand_acceptsWindowFlag() throws {
        let command = try ScreenshotCommand.parse(["--window", "2", "out.png"])
        XCTAssertEqual(command.windowTarget.window, 2)
        XCTAssertEqual(command.path, "out.png")
    }

    // MARK: - PdfCommand target wiring (#23)

    func testPdfCommand_defaultsNoTarget() throws {
        let command = try PdfCommand.parse([])
        XCTAssertNil(command.windowTarget.window)
    }

    func testPdfCommand_acceptsWindowFlag() throws {
        let command = try PdfCommand.parse(["--window", "2", "--allow-hid", "out.pdf"])
        XCTAssertEqual(command.windowTarget.window, 2)
        XCTAssertEqual(command.path, "out.pdf")
    }

    // MARK: - StorageCommand target wiring (#23)

    func testStorageLocalGet_acceptsUrlTarget() throws {
        let command = try StorageLocalGet.parse(["token", "--url", "plaud"])
        XCTAssertEqual(command.key, "token")
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    func testStorageLocalSet_acceptsDocumentTarget() throws {
        let command = try StorageLocalSet.parse(["k", "v", "--document", "2"])
        XCTAssertEqual(command.key, "k")
        XCTAssertEqual(command.value, "v")
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testStorageLocalRemove_acceptsWindowTarget() throws {
        let command = try StorageLocalRemove.parse(["k", "--window", "3"])
        XCTAssertEqual(command.target.resolve(), .windowIndex(3))
    }

    func testStorageLocalClear_acceptsTarget() throws {
        let command = try StorageLocalClear.parse(["--url", "oauth"])
        XCTAssertEqual(command.target.resolve(), .urlContains("oauth"))
    }

    func testStorageSessionGet_acceptsUrlTarget() throws {
        let command = try StorageSessionGet.parse(["sid", "--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    func testStorageSessionSet_acceptsTarget() throws {
        let command = try StorageSessionSet.parse(["k", "v", "--tab", "1"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(1))
    }

    func testStorageSessionRemove_acceptsTarget() throws {
        let command = try StorageSessionRemove.parse(["k", "--document", "4"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(4))
    }

    func testStorageSessionClear_acceptsTarget() throws {
        let command = try StorageSessionClear.parse(["--window", "2"])
        XCTAssertEqual(command.target.resolve(), .windowIndex(2))
    }

    func testStorageLocalGet_defaultTargetIsFrontWindow() throws {
        let command = try StorageLocalGet.parse(["token"])
        XCTAssertEqual(command.target.resolve(), .frontWindow)
    }

    // MARK: - SnapshotCommand target wiring (#23)

    func testSnapshotCommand_acceptsUrlTarget() throws {
        let command = try SnapshotCommand.parse(["--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlContains("plaud"))
    }

    func testSnapshotCommand_pageWithTarget() throws {
        let command = try SnapshotCommand.parse(["--page", "--document", "2"])
        XCTAssertTrue(command.page)
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testSnapshotCommand_defaultTargetIsFrontWindow() throws {
        let command = try SnapshotCommand.parse([])
        XCTAssertEqual(command.target.resolve(), .frontWindow)
    }
}

// MARK: - Equatable conformance for tests

extension SafariBridge.TargetDocument: Equatable {
    public static func == (lhs: SafariBridge.TargetDocument, rhs: SafariBridge.TargetDocument) -> Bool {
        switch (lhs, rhs) {
        case (.frontWindow, .frontWindow):
            return true
        case (.windowIndex(let l), .windowIndex(let r)):
            return l == r
        case (.urlContains(let l), .urlContains(let r)):
            return l == r
        case (.documentIndex(let l), .documentIndex(let r)):
            return l == r
        default:
            return false
        }
    }
}
