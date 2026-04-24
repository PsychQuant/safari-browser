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
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
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

    // MARK: - First-match plumbing (#33 url-matching-pipeline)

    func testJSCommandParsesFirstMatch() throws {
        // Integration test: verify `--first-match` is wired through
        // JSCommand's @OptionGroup to TargetOptions.firstMatch. Removing
        // the plumbing in TargetOptions would fail this test even before
        // the runtime path executes.
        let command = try JSCommand.parse([
            "document.title",
            "--url", "plaud",
            "--first-match",
        ])
        XCTAssertTrue(command.target.firstMatch,
                      "--first-match must be reachable via command.target.firstMatch")
        XCTAssertEqual(command.target.url, "plaud")
        let bundle = command.target.resolveWithFirstMatch()
        XCTAssertTrue(bundle.firstMatch,
                      "resolveWithFirstMatch() must carry firstMatch through")
        if case .urlMatch(.contains(let p)) = bundle.target {
            XCTAssertEqual(p, "plaud")
        } else {
            XCTFail("Expected .urlMatch(.contains('plaud'))")
        }
    }

    func testGetURLParsesUrlEndswith() throws {
        // Integration test for `--url-endswith`: exercises the new
        // precise-matching CLI flag through GetURL (GetCommand subcommand).
        let command = try GetURL.parse(["--url-endswith", "/play"])
        XCTAssertEqual(command.target.urlEndswith, "/play")
        if case .urlMatch(.endsWith(let s)) = command.target.resolve() {
            XCTAssertEqual(s, "/play")
        } else {
            XCTFail("Expected .urlMatch(.endsWith('/play'))")
        }
    }

    func testJSCommandRejectsConflictingUrlFlags() {
        // --url plaud + --url-endswith /play must fail validate() before
        // reaching run(). Locks the mutual-exclusion contract.
        XCTAssertThrowsError(
            try JSCommand.parse([
                "document.title",
                "--url", "plaud",
                "--url-endswith", "/play",
            ]).validate()
        ) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("mutually exclusive"),
                          "Error must identify the mutual exclusion: \(msg)")
        }
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
        XCTAssertEqual(options.resolve(), .urlMatch(.contains("plaud")))
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

    // MARK: - UploadCommand #24 JS file size hard cap

    func testUploadCommand_jsRejectsOver10MB() throws {
        let tmpFile = try Self.createTempFile(sizeBytes: 11 * 1_048_576)  // 11 MB
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        XCTAssertThrowsError(
            try UploadCommand.parse(["--js", "input", tmpFile]).validate()
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.contains("--js mode is capped at 10 MB"),
                "Expected 10 MB cap message, got: \(desc)"
            )
            XCTAssertTrue(
                desc.contains("--native"),
                "Error should point users to --native, got: \(desc)"
            )
        }
    }

    func testUploadCommand_jsAllowsUnder10MB() throws {
        let tmpFile = try Self.createTempFile(sizeBytes: 1024)  // 1 KB
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        XCTAssertNoThrow(
            try UploadCommand.parse(["--js", "input", tmpFile]).validate()
        )
    }

    func testUploadCommand_nativeAllowsLargeFile() throws {
        let tmpFile = try Self.createTempFile(sizeBytes: 200 * 1_048_576)  // 200 MB
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        // --native path bypasses the 10 MB cap (it uses the file dialog,
        // not the base64 JS path).
        XCTAssertNoThrow(
            try UploadCommand.parse(["--native", "input", tmpFile]).validate()
        )
    }

    func testUploadCommand_smartDefaultWithUrlTargetAllowsLargeFileAtValidate() throws {
        // #26 updates the smart-default routing: --url with no explicit
        // --js/--native now routes through the native-path resolver when
        // Accessibility permission is granted, so validate() can no
        // longer assume a large file + --url means JS. The 10 MB cap
        // only fires at validate() for explicit --js, and at run() for
        // the no-AX-perm JS fallback. Here we just assert validate()
        // does NOT throw for the targeting+large-file combo — the
        // runtime will decide the path.
        let tmpFile = try Self.createTempFile(sizeBytes: 11 * 1_048_576)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        XCTAssertNoThrow(
            try UploadCommand.parse(["input", tmpFile, "--url", "plaud"]).validate(),
            "Smart default with --url should no longer force JS path at validate time (#26)"
        )
    }

    func testUploadCommand_explicitJsWithUrlRejectsOver10MB() throws {
        // Explicit --js still rejects large files at validate time, and
        // the error message now points users to --native --url as the
        // #26-enabled alternative.
        let tmpFile = try Self.createTempFile(sizeBytes: 11 * 1_048_576)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        XCTAssertThrowsError(
            try UploadCommand.parse(["--js", "input", tmpFile, "--url", "plaud"]).validate()
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("--js mode is capped"), "Got: \(desc)")
            XCTAssertTrue(desc.contains("--native"), "Error should point to --native, got: \(desc)")
        }
    }

    func testUploadCommand_smartDefaultNoTargetingAllowsLargeFile() throws {
        // Without any targeting or explicit --js, smart default MAY route
        // to native (if AXIsProcessTrusted). Size cap should NOT fire at
        // validate time — run() decides mode based on permission state.
        let tmpFile = try Self.createTempFile(sizeBytes: 200 * 1_048_576)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        XCTAssertNoThrow(
            try UploadCommand.parse(["input", tmpFile]).validate()
        )
    }

    /// #24 source-level regression guard: the JS chunking path must use
    /// `Array.push` + `join`, NOT `String +=`. The old `+=` pattern caused
    /// V8 O(n²) string concatenation which allocated ~83 GB of transient
    /// garbage for a 131 MB file and crashed Safari even on 128 GB RAM.
    /// This test reads the source file directly so a future refactor that
    /// reverts to `+=` fails loudly at CI time.
    func testUploadCommand_jsChunkingUsesArrayPushNotStringConcat() throws {
        let sourcePath = Self.uploadCommandSourcePath()
        let src = try String(contentsOfFile: sourcePath, encoding: .utf8)

        // Must use array push (O(1) amortized) for chunk accumulation.
        XCTAssertTrue(
            src.contains("__sbUploadChunks.push"),
            "Chunked upload must use __sbUploadChunks.push to avoid V8 string concat O(n²) — see #24"
        )

        // Must NOT use String += pattern on window.__sbUpload.
        XCTAssertFalse(
            src.contains("__sbUpload += '"),
            "String += pattern forbidden on __sbUpload — causes 128 GB+ memory explosion (see #24)"
        )

        // Final join must be present for the DataTransfer injection.
        XCTAssertTrue(
            src.contains("__sbUploadChunks.join"),
            "DataTransfer injection must call __sbUploadChunks.join to materialize the full base64 string once"
        )
    }

    // Helpers for #24 tests

    private static func createTempFile(sizeBytes: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-upload-test-\(UUID().uuidString).bin")
        // Write zero bytes — macOS HFS+/APFS supports sparse files for this,
        // so 200 MB tests don't actually consume 200 MB on disk.
        let data = Data(count: sizeBytes)
        try data.write(to: url)
        return url.path
    }

    private static func uploadCommandSourcePath() -> String {
        // Walk up from this test file's location to find the source.
        // Tests run with cwd = package root, so relative path works.
        return "Sources/SafariBrowser/Commands/UploadCommand.swift"
    }

    // MARK: - UploadCommand target wiring (#23)

    func testUploadCommand_jsModeAcceptsUrlTarget() throws {
        let command = try UploadCommand.parse(["--js", "input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertTrue(command.js)
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
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

    // #26: native and --allow-hid now accept full TargetOptions. The
    // native-path resolver (SafariBridge.resolveNativeTarget) maps
    // --url / --tab / --document to a (window, tab) pair and performs
    // tab-switch + raise before keystroke dispatch. These tests lock
    // in the parse + validate contract; end-to-end resolution is
    // covered by WindowIndexResolverTests (pure) and task 10.1
    // (integration with live Safari).

    func testUploadCommand_nativeModeAcceptsUrlTarget() throws {
        // The old behavior (#23 R5) was to reject at parse-time. #26
        // removes that reject so the resolver can run at runtime.
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertTrue(command.native)
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    func testUploadCommand_nativeModeAcceptsTabTarget() throws {
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--tab", "2"])
        XCTAssertTrue(command.native)
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testUploadCommand_nativeModeAcceptsDocumentTarget() throws {
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--document", "2"])
        XCTAssertTrue(command.native)
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testUploadCommand_allowHidAcceptsUrlTarget() throws {
        // --allow-hid is a legacy alias for --native; same #26 relaxation applies.
        let command = try UploadCommand.parse(["--allow-hid", "input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertTrue(command.allowHid)
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    func testUploadCommand_nativeRejectsMutuallyExclusiveTargets() {
        // The mutually-exclusive check on TargetOptions itself still
        // fires — you can't pass --url AND --window on the same
        // invocation. This was never about native-vs-js; it's
        // TargetOptions hygiene.
        XCTAssertThrowsError(
            try UploadCommand.parse(["--native", "input", "/tmp/test.txt", "--url", "plaud", "--window", "2"])
        )
    }

    func testUploadCommand_smartDefaultAcceptsUrlTarget() throws {
        // Without explicit --native or --js, the smart default logic
        // picks at runtime. Parse-time validation cannot know the mode
        // in advance, so --url is accepted and the runtime path decides.
        let command = try UploadCommand.parse(["input", "/tmp/test.txt", "--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    // MARK: - TargetDocument.forWindow regression guard (#23 verify R2)

    func testTargetDocument_forWindow_mapsIntToWindowIndex() {
        // CRITICAL invariant: --window N MUST map to .windowIndex(N),
        // NOT .documentIndex(N). Safari's global document collection
        // index is NOT equivalent to "current tab of window N" in
        // multi-window sessions. The R0 implementation shipped with
        // .documentIndex and was only caught by devil's-advocate + codex
        // in R1 verify — this test locks the mapping so a regression
        // flips tests red immediately.
        XCTAssertEqual(SafariBridge.TargetDocument.forWindow(2), .windowIndex(2))
        XCTAssertEqual(SafariBridge.TargetDocument.forWindow(5), .windowIndex(5))
    }

    func testTargetDocument_forWindow_nilMapsToFrontWindow() {
        XCTAssertEqual(SafariBridge.TargetDocument.forWindow(nil), .frontWindow)
    }

    // #26: WindowOnlyTargetOptions has been removed — window-only
    // commands (close, screenshot, pdf, upload --native) now accept the
    // full TargetOptions surface. The pre-existing tests for the struct
    // itself are deleted along with the type. Tests for the new surface
    // live under each command's target-wiring section below, and the
    // TargetOptions parse contract (zero/negative window rejection,
    // mutual exclusion) is already covered by the TargetOptions tests
    // earlier in this file.

    // MARK: - #26 Backward compatibility invariants (source-level guards)

    /// Parse-level assertion: every window-capable command resolves to
    /// `.frontWindow` when no target flag is supplied, preserving the
    /// #23 "default target = document 1 = front window" invariant
    /// that existing scripts rely on (document-targeting spec MODIFIED
    /// "Backward compatibility with existing scripts" — "Keystroke
    /// operations preserve front-window semantics when no flag given"
    /// scenario). Runtime behavior is validated by task 10.1
    /// integration test.
    func testNoTargetFlagResolvesToFrontWindowForAllWindowCommands() throws {
        XCTAssertEqual(try UploadCommand.parse(["--native", "in", "/tmp/f"]).target.resolve(), .frontWindow)
        XCTAssertEqual(try CloseCommand.parse([]).target.resolve(), .frontWindow)
        XCTAssertEqual(try PdfCommand.parse(["--allow-hid", "o.pdf"]).target.resolve(), .frontWindow)
        XCTAssertEqual(try ScreenshotCommand.parse([]).target.resolve(), .frontWindow)
    }

    /// Source-level assertion: each native-path command routes
    /// targeting flags through `SafariBridge.resolveNativeTarget` so
    /// `--url plaud` on a non-front window correctly resolves + raises
    /// the plaud window before keystroke dispatch. This catches
    /// regressions where a refactor forgets to call the resolver and
    /// falls back to `target.window` directly — which would silently
    /// drop `--url` and keystroke the wrong window (the #23 R5 failure
    /// mode the resolver is supposed to eliminate).
    func testNativePathCommandsRouteThroughResolver() throws {
        for sourcePath in [
            "Sources/SafariBrowser/Commands/UploadCommand.swift",
            "Sources/SafariBrowser/Commands/CloseCommand.swift",
            "Sources/SafariBrowser/Commands/PdfCommand.swift",
        ] {
            let src = try String(contentsOfFile: sourcePath, encoding: .utf8)
            XCTAssertTrue(
                src.contains("resolveNativeTarget"),
                "\(sourcePath) must call resolveNativeTarget to honor --url/--tab/--document (#26)"
            )
        }
    }

    // MARK: - #26 Tab-switch interference warning

    /// Source-level assertion: upload --native and pdf emit a stderr
    /// addendum when tab switching is about to happen. Non-interference
    /// spec #26 requires the user to be informed that a background tab
    /// will be brought to the front as part of the keystroke sequence.
    /// Close is not required to warn (it's the closing operation
    /// itself, so tab switch is part of the user's intent).
    func testTabSwitchWarningEmittedForUploadAndPdf() throws {
        let uploadSrc = try String(contentsOfFile: "Sources/SafariBrowser/Commands/UploadCommand.swift", encoding: .utf8)
        XCTAssertTrue(
            uploadSrc.contains("Target tab will be brought to the front"),
            "UploadCommand must emit tab-switch stderr addendum when tabIndexInWindow is non-nil (#26)"
        )

        let pdfSrc = try String(contentsOfFile: "Sources/SafariBrowser/Commands/PdfCommand.swift", encoding: .utf8)
        XCTAssertTrue(
            pdfSrc.contains("Target tab will be brought to the front"),
            "PdfCommand must emit tab-switch stderr addendum when tabIndexInWindow is non-nil (#26)"
        )
    }

    // MARK: - CloseCommand target wiring (#23 → #26)

    func testCloseCommand_defaultsNoTarget() throws {
        let command = try CloseCommand.parse([])
        XCTAssertEqual(command.target.resolve(), .frontWindow)
    }

    func testCloseCommand_acceptsWindowFlag() throws {
        let command = try CloseCommand.parse(["--window", "2"])
        XCTAssertEqual(command.target.resolve(), .windowIndex(2))
    }

    // #26: close lost its WindowOnlyTargetOptions restriction — the
    // native-path resolver maps --url / --tab / --document to a
    // (window, tab) pair and tab-switches before `close current tab of
    // window N` runs, so every targeting flag is now valid.

    func testCloseCommand_acceptsUrlFlag() throws {
        let command = try CloseCommand.parse(["--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    func testCloseCommand_acceptsDocumentFlag() throws {
        let command = try CloseCommand.parse(["--document", "2"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testCloseCommand_acceptsTabFlag() throws {
        let command = try CloseCommand.parse(["--tab", "3"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(3))
    }

    func testCloseCommand_rejectsMutuallyExclusiveTargets() {
        // TargetOptions' mutual-exclusion check still applies — unchanged from #23.
        XCTAssertThrowsError(
            try CloseCommand.parse(["--url", "plaud", "--window", "2"])
        )
    }

    // MARK: - ScreenshotCommand target wiring (#23 → #26)

    func testScreenshotCommand_defaultsNoTarget() throws {
        let command = try ScreenshotCommand.parse([])
        XCTAssertEqual(command.target.resolve(), .frontWindow)
    }

    func testScreenshotCommand_acceptsWindowFlag() throws {
        let command = try ScreenshotCommand.parse(["--window", "2", "out.png"])
        XCTAssertEqual(command.target.resolve(), .windowIndex(2))
        XCTAssertEqual(command.path, "out.png")
    }

    // #26: screenshot accepts full TargetOptions. The key distinguishing
    // property vs upload/pdf/close is that screenshot does NOT tab-
    // switch — it observes without interfering. A --url that resolves to
    // a background tab captures the window's currently visible content.

    func testScreenshotCommand_acceptsUrlFlag() throws {
        let command = try ScreenshotCommand.parse(["--url", "plaud", "out.png"])
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    func testScreenshotCommand_acceptsDocumentFlag() throws {
        let command = try ScreenshotCommand.parse(["--document", "2", "out.png"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testScreenshotCommand_acceptsTabFlag() throws {
        let command = try ScreenshotCommand.parse(["--tab", "3", "out.png"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(3))
    }

    func testScreenshotCommand_acceptsFullWithUrl() throws {
        // --full --url plaud: doJavaScript reads dims from plaud via
        // document-scoped access, window-level ops use the resolved
        // window index.
        let command = try ScreenshotCommand.parse(["--full", "--url", "plaud", "out.png"])
        XCTAssertTrue(command.full)
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
    }

    func testScreenshotCommand_rejectsMutuallyExclusiveTargets() {
        XCTAssertThrowsError(
            try ScreenshotCommand.parse(["--url", "plaud", "--window", "2", "out.png"])
        )
    }

    /// #26 regression guard: screenshot source must NOT call
    /// `performTabSwitchIfNeeded`. Screenshot is non-interfering by
    /// design — tab-switching a background tab would break that
    /// contract. This source-level assertion catches any future
    /// refactor that tries to make screenshot "helpful" by
    /// auto-switching tabs.
    func testScreenshotCommand_sourceDoesNotTabSwitch() throws {
        let sourcePath = "Sources/SafariBrowser/Commands/ScreenshotCommand.swift"
        let src = try String(contentsOfFile: sourcePath, encoding: .utf8)
        XCTAssertFalse(
            src.contains("performTabSwitchIfNeeded"),
            "ScreenshotCommand must NOT tab-switch — breaks non-interference spec #26"
        )
    }

    // MARK: - PdfCommand target wiring (#23 → #26)

    func testPdfCommand_defaultsNoTarget() throws {
        let command = try PdfCommand.parse([])
        XCTAssertEqual(command.target.resolve(), .frontWindow)
    }

    func testPdfCommand_acceptsWindowFlag() throws {
        let command = try PdfCommand.parse(["--window", "2", "--allow-hid", "out.pdf"])
        XCTAssertEqual(command.target.resolve(), .windowIndex(2))
        XCTAssertEqual(command.path, "out.pdf")
    }

    // #26: pdf accepts full TargetOptions. Tab switch before keystroke
    // lets us export a background tab as PDF without the user manually
    // raising it first.

    func testPdfCommand_acceptsUrlFlag() throws {
        let command = try PdfCommand.parse(["--url", "docs", "--allow-hid", "out.pdf"])
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("docs")))
    }

    func testPdfCommand_acceptsDocumentFlag() throws {
        let command = try PdfCommand.parse(["--document", "2", "--allow-hid", "out.pdf"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(2))
    }

    func testPdfCommand_acceptsTabFlag() throws {
        let command = try PdfCommand.parse(["--tab", "3", "--allow-hid", "out.pdf"])
        XCTAssertEqual(command.target.resolve(), .documentIndex(3))
    }

    func testPdfCommand_rejectsMutuallyExclusiveTargets() {
        XCTAssertThrowsError(
            try PdfCommand.parse(["--url", "docs", "--window", "2", "--allow-hid", "out.pdf"])
        )
    }

    // MARK: - StorageCommand target wiring (#23)

    func testStorageLocalGet_acceptsUrlTarget() throws {
        let command = try StorageLocalGet.parse(["token", "--url", "plaud"])
        XCTAssertEqual(command.key, "token")
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
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
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("oauth")))
    }

    func testStorageSessionGet_acceptsUrlTarget() throws {
        let command = try StorageSessionGet.parse(["sid", "--url", "plaud"])
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
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
        XCTAssertEqual(command.target.resolve(), .urlMatch(.contains("plaud")))
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
        case (.urlMatch(let l), .urlMatch(let r)):
            return l == r
        case (.windowTab(let lw, let lt), .windowTab(let rw, let rt)):
            return lw == rw && lt == rt
        case (.documentIndex(let l), .documentIndex(let r)):
            return l == r
        default:
            return false
        }
    }
}
