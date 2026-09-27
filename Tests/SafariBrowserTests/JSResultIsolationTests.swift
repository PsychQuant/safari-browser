import Foundation
import JavaScriptCore
import XCTest
@testable import SafariBrowser

/// Execute the production JS wrappers through the bridge's existing runner seam.
/// No Safari, Apple events or external web requests are used.
final class JSResultIsolationTests: XCTestCase, @unchecked Sendable {
    func testLargeOutputCannotReturnAnotherInvocationResult() async throws {
        let page = try ScriptPage(interleave: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("result.txt")
        var command = try JSCommand.parse(["--large", "--output", output.path, "'new-batch'"])
        command.target.profile = nil
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(request) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                try await page.run(source)
            }) { try await command.run() }
        }
        let interleaved = await page.didInterleave()
        XCTAssertTrue(interleaved)
        let remaining = await page.evaluateJS("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).length")
        XCTAssertEqual(remaining, "1", "Cleanup must leave the other invocation intact")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "new-batch")
    }
    func testExpressionReadsPageBindingRatherThanWrapperTemporary() async throws {
        let page = try ScriptPage(interleave: false)
        _ = await page.evaluateJS("var s = 42")
        let value = try await JavaScriptResultSession().execute("s", allowStatements: true, chunked: false) {
            await page.evaluateJS($0)
        }
        XCTAssertEqual(value, "42")
    }
    func testExpressionsStatementsEmptyAndTrailingComments() async throws {
        let cases = [("'\u{0301}tail'", "\u{0301}tail"), ("1 + 1 // trailing", "2"), ("var a=2; return a+3; // trailing", "5"),
                     ("''", ""), ("null", "null"), ("undefined", "undefined"),
                     ("var a=2; a+3", "undefined"), ("':start:\\nend:\\n'", ":start:\nend:\n")]
        for (code, expected) in cases {
            let page = try ScriptPage(interleave: false)
            let result = try await JavaScriptResultSession().execute(code, allowStatements: true, chunked: false) {
                await page.evaluateJS($0)
            }
            XCTAssertEqual(result, expected, code)
            let leftovers = await page.evaluateJS("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).length")
            XCTAssertEqual(leftovers, "0")
        }
    }

    func testRuntimeExceptionIsNotRetriedAndKeepsThrownValue() async throws {
        for thrown in ["new Error('boom')", "null", "'text failure'"] {
            let page = try ScriptPage(interleave: false)
            do {
                _ = try await JavaScriptResultSession().execute(
                    "window.counter=(window.counter||0)+1; throw \(thrown)", allowStatements: true, chunked: true
                ) { await page.evaluateJS($0) }
                XCTFail("Expected JavaScript error")
            } catch SafariBrowserError.appleScriptFailed(let message) {
                XCTAssertTrue(message.contains("JavaScript error:"))
            }
            let count = await page.evaluateJS("window.counter")
            XCTAssertEqual(count, "1")
        }
    }

    func testMissingExecutionStateDoesNotReplaySideEffects() async throws {
        let page = try ScriptPage(interleave: false, fault: .eraseExecutedState)
        do {
            _ = try await JavaScriptResultSession().execute(
                "window.counter=(window.counter||0)+1; return 'done'", allowStatements: true, chunked: true
            ) { await page.evaluateJS($0) }
            XCTFail("Expected unavailable result")
        } catch JavaScriptResultSession.TransferFailure.executionResultLost { }
        let count = await page.evaluateJS("window.counter")
        XCTAssertEqual(count, "1")
    }

    func testLargeFallbackReadsOnceCapturedValueAndPreservesUnicodeBoundary() async throws {
        let page = try ScriptPage(interleave: false, maximumReplyLength: 300_000)
        let expected = String(repeating: "A", count: 262_143) + "😀" + String(repeating: "B", count: 40_000) + "\n"
        let result = try await JavaScriptResultSession().execute(
            "window.counter=(window.counter||0)+1; return 'A'.repeat(262143)+'😀'+'B'.repeat(40000)+'\\n'",
            allowStatements: true, chunked: false
        ) { await page.evaluateJS($0) }
        XCTAssertEqual(result, expected)
        let count = await page.evaluateJS("window.counter")
        XCTAssertEqual(count, "1")
    }

    func testInvalidUTF16FailsRatherThanPublishingReplacementCharacters() async throws {
        let page = try ScriptPage(interleave: false)
        do {
            _ = try await JavaScriptResultSession().execute("'\\uD800'", allowStatements: false, chunked: true) {
                await page.evaluateJS($0)
            }
            XCTFail("Expected malformed Unicode failure")
        } catch let error as JavaScriptResultSession.TransferFailure {
            XCTAssertTrue(error.description.contains("UTF-16"))
        }
    }

    func testInitializationMismatchDoesNotExecuteCode() async throws {
        let page = try ScriptPage(interleave: false)
        let session = JavaScriptResultSession()
        do {
            _ = try await session.execute("window.counter=1", allowStatements: true, chunked: true) { script in
                if script == session.prepareScript { return "old-token:prepared" }
                return await page.evaluateJS(script)
            }
            XCTFail("Expected unavailable result")
        } catch JavaScriptResultSession.TransferFailure.preparationFailed { }
        let count = await page.evaluateJS("typeof window.counter")
        XCTAssertEqual(count, "undefined")
    }

    func testStaleAndShortFramesPreserveExistingOutputFile() async throws {
        for fault in [ScriptPage.Fault.staleFrame, .shortFrame] {
            let page = try ScriptPage(interleave: false, fault: fault)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent("result.txt")
            try "keep-me".write(to: output, atomically: true, encoding: .utf8)
            let command = try JSCommand.parse(["--large", "--output", output.path, "'new-batch'"])
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            do {
                try await DaemonRequestContext.$current.withValue(request) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                        try await command.run()
                    }
                }
                XCTFail("Expected frame failure")
            } catch JavaScriptResultSession.TransferFailure.malformed { }
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep-me")
        }
    }

    func testMetadataAndOffsetCorruptionFailWithoutRetry() async throws {
        for fault in [ScriptPage.Fault.invalidLength, .wrongOffset] {
            let page = try ScriptPage(interleave: false, fault: fault)
            do {
                _ = try await JavaScriptResultSession().execute(
                    "(function(){window.counter=(window.counter||0)+1; return 'new-batch'})()", allowStatements: true, chunked: true
                ) { await page.evaluateJS($0) }
                XCTFail("Expected transfer failure")
            } catch is JavaScriptResultSession.TransferFailure { }
            let count = await page.evaluateJS("window.counter")
            XCTAssertEqual(count, "1")
        }
    }

    func testMissingLaterChunkFailsInsteadOfReturningPartialResult() async throws {
        let page = try ScriptPage(interleave: false, fault: .emptySecondFrame)
        do {
            _ = try await JavaScriptResultSession().execute("'A'.repeat(300000)", allowStatements: false, chunked: true) {
                await page.evaluateJS($0)
            }
            XCTFail("Expected incomplete result failure")
        } catch JavaScriptResultSession.TransferFailure.malformed { }
    }

    func testProtocolDoesNotDependOnPageStringGlobal() async throws {
        let page = try ScriptPage(interleave: false)
        _ = await page.evaluateJS("window.String=function(){return 'wrong'}")
        let value = try await JavaScriptResultSession().execute("1+1", allowStatements: true, chunked: true) {
            await page.evaluateJS($0)
        }
        XCTAssertEqual(value, "2")
    }

    func testUnparseableCodeReportsSyntaxErrorAndCleansState() async throws {
        let page = try ScriptPage(interleave: false)
        do {
            _ = try await JavaScriptResultSession().execute("1+", allowStatements: true, chunked: false) {
                await page.evaluateJS($0)
            }
            XCTFail("Expected syntax error")
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertTrue(message.contains("JavaScript syntax error"))
        }
        let leftovers = await page.evaluateJS("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).length")
        XCTAssertEqual(leftovers, "0")
    }

    func testFailedPreparationCannotBecomeSuccessfulNavigation() async throws {
        let page = try ScriptPage(interleave: false, fault: .rejectPreparationAfterNavigation)
        let command = try JSCommand.parse(["window.counter=1"])
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(request) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                    try await command.run()
                }
            }
            XCTFail("Failed preparation must not report successful execution")
        } catch JavaScriptResultSession.TransferFailure.preparationFailed { }
        let counter = await page.evaluateJS("typeof window.counter")
        XCTAssertEqual(counter, "undefined")
    }

    func testNavigationSuccessRequiresExecutionEvidenceAndDoesNotPublishEmptyFile() async throws {
        for (fault, success) in [(ScriptPage.Fault.navigateAfterExecution, true), (.navigateWithoutReceipt, false)] {
            let page = try ScriptPage(interleave: false, fault: fault)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try "keep-me".write(to: output, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: output) }
            let command = try JSCommand.parse(["--output", output.path, "window.counter=(window.counter||0)+1; return 'done'"])
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            do {
                try await DaemonRequestContext.$current.withValue(request) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                        try await command.run()
                    }
                }
                XCTAssertTrue(success, "An unconfirmed execution must remain a failure")
            } catch JavaScriptResultSession.TransferFailure.unavailable {
                XCTAssertFalse(success)
            }
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep-me")
            let counter = await page.evaluateJS("window.counter")
            XCTAssertEqual(counter, "1")
        }
    }

    func testExecutionReceiptConflictingWithPreparedMetadataNeverDispatchesFallback() async throws {
        let page = try ScriptPage(interleave: false, fault: .preparedAfterReceipt)
        do {
            _ = try await JavaScriptResultSession().execute("(window.counter=1)", allowStatements: true, chunked: false) {
                await page.evaluateJS($0)
            }
            XCTFail("Expected inconsistent state failure")
        } catch JavaScriptResultSession.TransferFailure.malformed { }
        let attempts = await page.executionCallCount()
        XCTAssertEqual(attempts, 1)
    }


    // The XCTest runner executes this suite serially, as with the repository's
    // existing descriptor-capture tests. Use a file so large output cannot fill a pipe.
    private func captureStdout(_ body: () async throws -> Void) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        fflush(nil)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(saved) }
        guard dup2(fd, STDOUT_FILENO) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { fflush(nil); _ = dup2(saved, STDOUT_FILENO) }
        try await body()
        fflush(nil)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testGetTextAndHTMLLargeFallbacksUseOwnedState() async throws {
        for html in [false, true] {
            let page = try ScriptPage(interleave: false, maximumReplyLength: 300_000)
            _ = await page.evaluateJS("var fixture={textContent:'G'.repeat(300001),innerHTML:'<p>'+'G'.repeat(300001)+'</p>'}; var document={querySelector:function(){return fixture}}")
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            let output = try await captureStdout {
                try await DaemonRequestContext.$current.withValue(request) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                        if html { try await GetHTML.parse(["#fixture"]).run() }
                        else { try await GetText.parse(["#fixture"]).run() }
                    }
                }
            }
            let text = String(repeating: "G", count: 300001)
            XCTAssertEqual(output, (html ? "<p>" + text + "</p>" : text) + "\n")
            let shared = await page.wroteSharedResult()
            XCTAssertFalse(shared)
            let frames = await page.framesRead()
            XCTAssertGreaterThan(frames, 1)
        }
    }

    func testBothSnapshotModesUseOwnedLargeFallback() async throws {
        for fullPage in [false, true] {
            let page = try ScriptPage(interleave: false, maximumReplyLength: 300_000)
            _ = await page.evaluateJS("""
                var fixture={offsetParent:{},nodeType:1,tagName:'BUTTON',type:'button',id:'G'.repeat(300001),classList:[],textContent:'hello',getAttribute:function(){return null}};
                var root={nodeType:1,tagName:'BODY',childNodes:[],getAttribute:function(){return null},querySelectorAll:function(){return [fixture]}};
                var document={body:root,title:'G'.repeat(300001),readyState:'complete'};
                window.location={href:'https://fixture.invalid/'};
                function getComputedStyle(){return {display:'block',visibility:'visible'}};
                """)
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            let output = try await captureStdout {
                try await DaemonRequestContext.$current.withValue(request) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                        try await SnapshotCommand.parse(fullPage ? ["--page", "--json"] : ["--json"]).run()
                    }
                }
            }
            let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8))
            if fullPage {
                XCTAssertEqual((parsed as? [String: Any])?["title"] as? String, String(repeating: "G", count: 300001))
            } else {
                XCTAssertEqual((parsed as? [[String: Any]])?.first?["id"] as? String, String(repeating: "G", count: 300001))
            }
            let frames = await page.framesRead()
            XCTAssertGreaterThan(frames, 1)
        }
    }

    func testNonceSessionsDoNotAccumulateCompiledHandles() async throws {
        let page = try ScriptPage(interleave: false)
        let cache = PreCompiledScripts.CompileCache()
        _ = try await DaemonDispatch.Handlers.cachedScriptText(source: "return 42", cache: cache)
        for _ in 0..<4 {
            let value = try await JavaScriptResultSession().execute("'x'", allowStatements: true, chunked: true) { script in
                let reply = await page.evaluateJS(script)
                // Exercise the production in-process cache route with real
                // NSAppleScript, using only a harmless return (no Safari).
                return try await DaemonDispatch.Handlers.cachedScriptText(
                    source: "return \"\(reply.escapedForAppleScript)\"", cache: cache)
            }
            XCTAssertEqual(value, "x")
        }
        let retained = await cache.cacheCount
        XCTAssertEqual(retained, 1, "Only the reusable prewarmed script should remain")
    }

    func testExactURLGuardNavigationRunsThroughRealBridgeRetryAndSettlement() async throws {
        let page = try ScriptPage(interleave: false, fault: .navigateAfterExecution)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "keep-me".write(to: output, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: output) }
        let command = try JSCommand.parse(["--url-exact", "https://fixture.invalid/", "--output", output.path,
            "window.counter=(window.counter||0)+1; return 'done'"])
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(request) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                try await command.run()
            }
        }
        let count = await page.evaluateJS("window.counter")
        XCTAssertEqual(count, "1")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep-me")
    }

    func testFinalGuardedTargetChangeIsMappedOnlyAfterExecutionReceipt() async throws {
        for afterExecution in [false, true] {
            let page = try ScriptPage(interleave: false)
            let session = JavaScriptResultSession()
            do {
                _ = try await session.execute("(window.counter=1)", allowStatements: true, chunked: true) { script in
                    if (!afterExecution && script == session.prepareScript)
                        || (afterExecution && script.contains("s.phase+':'+s.text.length")) {
                        // Final error emitted after the bridge's matcher retry
                        // cannot find the original URL following navigation.
                        throw SafariBrowserError.targetTabChanged(expected: "fixture.invalid", actualURL: nil)
                    }
                    return await page.evaluateJS(script)
                }
                XCTFail("Expected guarded target change")
            } catch JavaScriptResultSession.TransferFailure.executionResultLost {
                XCTAssertTrue(afterExecution)
            } catch SafariBrowserError.targetTabChanged {
                XCTAssertFalse(afterExecution, "Confirmed execution must reach the navigation decision path")
            }
            let counter = await page.evaluateJS("typeof window.counter==='undefined'?'undefined':window.counter")
            XCTAssertEqual(counter, afterExecution ? "1" : "undefined")
        }
    }

    func testStateLostDuringFrameReadCanSettleConfirmedNavigation() async throws {
        let page = try ScriptPage(interleave: false, fault: .eraseBeforeFrame)
        let command = try JSCommand.parse(["--large", "window.counter=1; return 'done'"])
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(request) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                try await command.run()
            }
        }
        let count = await page.evaluateJS("window.counter")
        XCTAssertEqual(count, "1")
    }

    func testCancellationAtProtocolBoundariesNeverReturnsPublishableResult() async throws {
        for boundary in ["prepare", "execute", "frame", "cleanup"] {
            let page = try ScriptPage(interleave: false)
            let session = JavaScriptResultSession()
            let task = Task {
                try await session.execute("(window.counter=1)", allowStatements: true, chunked: true) { script in
                    let result = await page.evaluateJS(script)
                    let cancel = (boundary == "prepare" && script == session.prepareScript)
                        || (boundary == "execute" && (result.hasSuffix(":done") || result.hasSuffix(":error")))
                        || (boundary == "frame" && script.contains("var text=s.text,end="))
                        || (boundary == "cleanup" && script == session.cleanupScript)
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    return result
                }
            }
            do {
                _ = try await task.value
                XCTFail("Cancellation at \(boundary) must not return a result")
            } catch is CancellationError { }
            let count = await page.evaluateJS("typeof window.counter==='undefined'?'undefined':window.counter")
            XCTAssertEqual(count, boundary == "prepare" ? "undefined" : "1")
        }
    }

    func testGetTextWithoutSelectorUsesCheckedFallbackAndReportsMissingBody() async throws {
        for hasBody in [true, false] {
            let page = try ScriptPage(interleave: false, maximumReplyLength: 300_000)
            _ = await page.evaluateJS(hasBody ? "var document={body:{innerText:'T'.repeat(300001)}}" : "var document={}")
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            do {
                let output = try await captureStdout {
                    try await DaemonRequestContext.$current.withValue(request) {
                        try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                            try await GetText.parse([]).run()
                        }
                    }
                }
                XCTAssertTrue(hasBody)
                XCTAssertEqual(output, String(repeating: "T", count: 300001) + "\n")
            } catch SafariBrowserError.appleScriptFailed(let message) {
                XCTAssertFalse(hasBody)
                XCTAssertTrue(message.contains("JavaScript error:"))
            }
        }
    }

    func testGetLargeFallbackRuntimeErrorsRemainExplicit() async throws {
        for html in [false, true] {
            let page = try ScriptPage(interleave: false, maximumReplyLength: 300_000)
            let property = html ? "innerHTML" : "textContent"
            _ = await page.evaluateJS("var reads=0; var fixture={}; Object.defineProperty(fixture,'\(property)',{get:function(){if(++reads===3)throw new Error('owned fallback failure');return 'G'.repeat(300001)}}); var document={querySelector:function(){return fixture}}")
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            do {
                _ = try await captureStdout {
                    try await DaemonRequestContext.$current.withValue(request) {
                        try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                            if html { try await GetHTML.parse(["#fixture"]).run() }
                            else { try await GetText.parse(["#fixture"]).run() }
                        }
                    }
                }
                XCTFail("A fallback exception must not become a successful empty result")
            } catch SafariBrowserError.appleScriptFailed(let message) {
                XCTAssertTrue(message.contains("owned fallback failure"))
            }
            let reads = await page.evaluateJS("reads")
            XCTAssertEqual(reads, "3")
        }
    }

    func testAlreadyCancelledCommandDoesNotDispatchAnyAppleScript() async throws {
        let page = try ScriptPage(interleave: false)
        let task = Task {
            let command = try JSCommand.parse(["window.counter=1"])
            let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            withUnsafeCurrentTask { $0?.cancel() }
            try await DaemonRequestContext.$current.withValue(request) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                    try await command.run()
                }
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let calls = await page.scriptCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testRuntimeErrorCannotBeSettledAsNavigationSuccess() async throws {
        let page = try ScriptPage(interleave: false, fault: .navigateAfterExecution)
        let command = try JSCommand.parse(["--large", "window.counter=1; throw new Error('owned runtime failure')"])
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(request) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                    try await command.run()
                }
            }
            XCTFail("A reported runtime error must not turn into navigation success")
        } catch JavaScriptResultSession.TransferFailure.runtimeErrorDetailsLost { }
        let count = await page.evaluateJS("window.counter")
        XCTAssertEqual(count, "1")
    }

    func testSharedLargeBridgeUsesCapturedResultProtocol() async throws {
        let page = try ScriptPage(interleave: false)
        let request = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let result = try await DaemonRequestContext.$current.withValue(request) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try await page.run($0) }) {
                try await SafariBridge.doJavaScriptLarge("'bridge😀'.repeat(50000)")
            }
        }
        XCTAssertEqual(result, String(repeating: "bridge😀", count: 50000))
    }

}

private actor ScriptPage {
    enum Fault { case none, staleFrame, shortFrame, eraseExecutedState, invalidLength, wrongOffset, emptySecondFrame, rejectPreparationAfterNavigation, navigateAfterExecution, navigateWithoutReceipt, preparedAfterReceipt, eraseBeforeFrame }
    private let fault: Fault
    private let maximumReplyLength: Int?
    private let context: JSContext
    private let interleave: Bool
    private var interleaved = false
    private var frameCount = 0
    private var executionCalls = 0
    private var scriptCalls = 0
    private var sharedResultWritten = false
    private var pageURL = "https://fixture.invalid/"

    init(interleave: Bool, fault: Fault = .none, maximumReplyLength: Int? = nil) throws {
        guard let context = JSContext() else { throw CocoaError(.coderInvalidValue) }
        self.context = context
        self.interleave = interleave
        self.fault = fault
        self.maximumReplyLength = maximumReplyLength
        context.evaluateScript("var window = globalThis")
    }

    func didInterleave() -> Bool { interleaved }
    func executionCallCount() -> Int { executionCalls }
    func scriptCallCount() -> Int { scriptCalls }
    func framesRead() -> Int { frameCount }
    func wroteSharedResult() -> Bool { sharedResultWritten }

    func run(_ source: String) throws -> String {
        scriptCalls += 1
        if source.contains("SB_TARGET_CHANGED") && pageURL != "https://fixture.invalid/" {
            throw SafariBrowserError.appleScriptFailed("SB_TARGET_CHANGED")
        }
        guard let start = source.range(of: "do JavaScript \"") else {
            if source.contains("set GS to (character id 29)") {
                return ["1", "1", "1", pageURL, "Fixture", "Fixture", "71"].joined(separator: "\u{1d}") + "\u{1e}"
            }
            if source.contains("get id of window") { return "71" }
            if source.contains("URL of") { return pageURL }
            if source.contains("text of") { return "" }
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "Unexpected non-JS fixture source: \(source)"])
        }
        let opening = source.index(before: start.upperBound)
        var cursor = start.upperBound
        var escaped = false
        while cursor < source.endIndex {
            let char = source[cursor]
            if !escaped && char == "\"" { break }
            if !escaped && char == "\\" { escaped = true } else { escaped = false }
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex else { throw CocoaError(.coderInvalidValue) }
        let literal = String(source[opening...cursor])
        let js = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        return evaluateJS(js)
    }

    func evaluateJS(_ js: String) -> String {
        if fault == .eraseBeforeFrame && js.contains("var text=s.text,end=") {
            context.evaluateScript("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).forEach(k=>delete window[k])")
            pageURL = "https://fixture.invalid/after"
        }
        if js.contains("window.__sbResult =") { sharedResultWritten = true }
        if js.contains(".phase='running';try{") { executionCalls += 1 }
        context.exception = nil
        let value = context.evaluateScript(js)
        // Safari do JavaScript swallows uncaught JS exceptions as empty text.
        let result = context.exception == nil && value?.isUndefined == false ? value?.toString() ?? "" : ""
        context.exception = nil
        if interleave && !interleaved && js.contains("'new-batch'") {
            // Another legitimate `js` invocation reaches its store step before
            // the first invocation reads its result; both payloads have length 9.
            if js.contains("__sbInvocation_") {
                let other = JavaScriptResultSession()
                context.evaluateScript(other.prepareScript)
                context.evaluateScript(JSWrapper.invocationWrapper("'old-batch'", key: other.key, token: other.token, statement: false))
            } else {
                context.evaluateScript("window.__sbResult = 'old-batch'; window.__sbLen = 9")
            }
            interleaved = true
        }
        if fault == .rejectPreparationAfterNavigation && result.hasSuffix(":prepared") {
            pageURL = "https://fixture.invalid/after"
            return "stale-token:prepared"
        }
        if (fault == .navigateAfterExecution || fault == .navigateWithoutReceipt) && (result.hasSuffix(":done") || result.hasSuffix(":error")) {
            context.evaluateScript("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).forEach(k=>delete window[k])")
            pageURL = "https://fixture.invalid/after"
            if fault == .navigateWithoutReceipt { return "" }
        }
        if fault == .preparedAfterReceipt && js.contains("s.phase+':'+s.text.length") {
            return result.split(separator: ":").first.map { String($0) + ":prepared:0" } ?? ""
        }
        if fault == .eraseExecutedState && (result.hasSuffix(":done") || result.hasSuffix(":error")) {
            context.evaluateScript("Object.keys(window).filter(k=>k.startsWith('__sbInvocation_')).forEach(k=>delete window[k])")
        }
        if fault == .invalidLength && js.contains("s.phase+':'+s.text.length") {
            return result.split(separator: ":").prefix(2).joined(separator: ":") + ":NaN"
        }
        if js.contains("var text=s.text,end=") {
            frameCount += 1
            if fault == .emptySecondFrame && frameCount == 2 { return "" }
            if fault == .wrongOffset { return result.replacingOccurrences(of: ":0:", with: ":1:") }
            if fault == .staleFrame, let colon = result.firstIndex(of: ":") {
                return "stale-token" + result[colon...]
            }
            if fault == .shortFrame { return result.replacingOccurrences(of: ":new-batch:", with: ":short:") }
        }
        if let maximumReplyLength, result.utf16.count > maximumReplyLength { return "" }
        return result
    }
}
