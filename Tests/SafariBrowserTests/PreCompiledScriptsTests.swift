import XCTest
import Foundation
@testable import SafariBrowser

/// Covers `Daemon uses pre-compiled NSAppleScript handles, not process warmth,
/// for latency reduction`. We verify the compile cache reuses handles, that
/// placeholder rendering is strict, and that a trivial script executes end-to-end
/// without a Safari dependency.
final class PreCompiledScriptsTests: XCTestCase {

    // MARK: - Template catalog

    func testKnownTemplates_containPhase1Seeds() {
        let known = PreCompiledScripts.known
        XCTAssertNotNil(known["activateWindow"])
        XCTAssertNotNil(known["enumerateWindows"])
        XCTAssertNotNil(known["runJSInCurrentTab"])
    }

    func testTemplate_placeholdersAreDerivedFromSource() {
        let template = PreCompiledScripts.Template.parse(
            name: "demo",
            source: "hello {{NAME}} from {{GREETING}}"
        )
        XCTAssertEqual(template.placeholders, ["NAME", "GREETING"])
    }

    // MARK: - Rendering

    func testRender_substitutesPlaceholders() throws {
        let rendered = try PreCompiledScripts.render(
            template: PreCompiledScripts.Template.parse(
                name: "demo",
                source: "set idx to {{WINDOW_INDEX}}"
            ),
            params: ["WINDOW_INDEX": "3"]
        )
        XCTAssertEqual(rendered, "set idx to 3")
    }

    func testRender_missingPlaceholder_throws() {
        let tmpl = PreCompiledScripts.Template.parse(
            name: "demo",
            source: "{{REQUIRED}}"
        )
        XCTAssertThrowsError(try PreCompiledScripts.render(template: tmpl, params: [:])) { err in
            guard case PreCompiledScripts.Error.missingPlaceholder(let name) = err else {
                return XCTFail("expected missingPlaceholder, got \(err)")
            }
            XCTAssertEqual(name, "REQUIRED")
        }
    }

    func testRender_extraParamIsIgnored() throws {
        let tmpl = PreCompiledScripts.Template.parse(name: "demo", source: "x = {{A}}")
        let rendered = try PreCompiledScripts.render(
            template: tmpl,
            params: ["A": "1", "B": "unused"]
        )
        XCTAssertEqual(rendered, "x = 1")
    }

    func testRender_activateWindowTemplate() throws {
        let tmpl = try XCTUnwrap(PreCompiledScripts.known["activateWindow"])
        let rendered = try PreCompiledScripts.render(
            template: tmpl,
            params: ["WINDOW_INDEX": "2"]
        )
        XCTAssertTrue(rendered.contains("set index of window 2 to 1"))
        XCTAssertTrue(rendered.contains("activate"))
        XCTAssertFalse(rendered.contains("{{"))
    }

    // MARK: - Compile cache

    func testCompileCache_reusesCompiledEntry() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let source = "return 1 + 1"
        try await cache.compile(source: source)
        try await cache.compile(source: source)
        let count = await cache.cacheCount
        XCTAssertEqual(count, 1, "second compile of the same source should hit the cache")
    }

    func testCompileCache_distinctSourcesProduceDistinctEntries() async throws {
        let cache = PreCompiledScripts.CompileCache()
        try await cache.compile(source: "return 1")
        try await cache.compile(source: "return 2")
        let count = await cache.cacheCount
        XCTAssertEqual(count, 2)
    }

    func testCompileCache_containsReflectsState() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let absent = await cache.contains(source: "return 1")
        XCTAssertFalse(absent)
        try await cache.compile(source: "return 1")
        let present = await cache.contains(source: "return 1")
        XCTAssertTrue(present)
    }

    func testCompileCache_invalidSourceThrowsCompilationFailed() async {
        let cache = PreCompiledScripts.CompileCache()
        do {
            try await cache.compile(source: "this is not a valid applescript !!!")
            XCTFail("expected compilation to fail")
        } catch PreCompiledScripts.Error.compilationFailed {
            // ok
        } catch {
            XCTFail("expected compilationFailed, got \(error)")
        }
    }

    // MARK: - Execution (no Safari dependency)

    func testExecute_trivialArithmetic_returnsCorrectResult() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let result = try await cache.execute(source: "return 40 + 2")
        XCTAssertEqual(result.int32Value, 42)
    }

    func testExecute_cachesOnFirstCall() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let source = "return 7"
        _ = try await cache.execute(source: source)
        _ = try await cache.execute(source: source)
        let count = await cache.cacheCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - #218: daemon-path errors keep their AppleScript code

    func testExecutionErrorsCarryTheirCodeLikeOsascript() async throws {
        // NSAppleScript puts the code in NSAppleScriptErrorNumber, not in the
        // message; osascript appends it. Classifiers read the code.
        let cache = PreCompiledScripts.CompileCache()
        for (code, text) in [(-1719, "Can’t get tab 9 of window id 101. Invalid index."), (-1728, "Can’t get window id 999.")] {
            do {
                _ = try await DaemonDispatch.Handlers.cachedScriptText(
                    source: "error \"\(text)\" number \(code)", cache: cache)
                XCTFail("the script raises")
            } catch let error as SafariBrowserError {
                guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.hasSuffix("(\(code))"), message)
                XCTAssertTrue(message.contains(text), message)
                XCTAssertTrue(SafariBridge.isTargetDangleError(error), "a dangle on the daemon path must be recognised: \(message)")
            }
        }
    }

    func testCompilationErrorsCarryTheirCode() async {
        let cache = PreCompiledScripts.CompileCache()
        do {
            try await cache.compile(source: "this is not ) applescript (")
            XCTFail("the source does not compile")
        } catch PreCompiledScripts.Error.compilationFailed(let message) {
            XCTAssertNotNil(message.range(of: #"\(-?\d+\)$"#, options: .regularExpression), message)
        } catch { XCTFail("\(error)") }
    }

    func testDescribeKeepsTheCodeForEveryMessageShape() {
        typealias Cache = PreCompiledScripts.CompileCache
        // The daemon's locale decides the message language; the code does not
        // change with it.
        let localized: NSDictionary = ["NSAppleScriptErrorMessage": "Safari發生錯誤：無法取得「window id 999999」。",
                                       "NSAppleScriptErrorNumber": NSNumber(value: -1728)]
        XCTAssertEqual(Cache.describe(localized), "Safari發生錯誤：無法取得「window id 999999」。 (-1728)")
        XCTAssertTrue(SafariBridge.isObjectNotFound(Cache.describe(localized)))
        XCTAssertTrue(SafariBridge.isTargetDangleError(.appleScriptFailed(Cache.describe(localized))))
        let noCode: NSDictionary = ["NSAppleScriptErrorMessage": "Can’t get window 2."]
        XCTAssertEqual(Cache.describe(noCode), "Can’t get window 2.", "no code: the message is unchanged")
        let noMessage: NSDictionary = ["NSAppleScriptErrorNumber": NSNumber(value: -1719)]
        XCTAssertEqual(Cache.describe(noMessage), "AppleScript error (-1719)", "the code appears once")
    }

    func testNotFoundIsDecidedByTheCodeAlone() {
        for text in ["6:14: execution error: Safari發生錯誤：無法取得「window 2」。 (-1728)",   // constructed: osascript prefix, zh-TW body
                     "Safari got an error: Can’t get tab 9 of window id 101. Invalid index. (-1719)"] {   // daemon shape
            XCTAssertTrue(SafariBridge.isObjectNotFound(text), text)
        }
        for text in ["Can’t get window 2.", "無法取得「window 2」。", "Can't get it (-2700)", "broken (-2700)"] {
            XCTAssertFalse(SafariBridge.isObjectNotFound(text), text)
        }
    }

    func testOnlyTheTrailingCodeCounts() {
        // A body that mentions -1728 or -1719 but ends in another code is not
        // "not found": the number in the text is content (a URL, a title), not
        // the error number. Both classifiers must agree on every one of these.
        let mentionsButEndsElsewhere = ["body -1728 text (-10006)",
                                        "Can’t make -1719 into type text (-1700)",
                                        "x -1728 y (-2700)",
                                        "Can’t get https://example.com/item-1728. (-1700)"]
        for text in mentionsButEndsElsewhere {
            XCTAssertFalse(SafariBridge.isObjectNotFound(text), text)
            XCTAssertFalse(SafariBridge.isTargetDangleError(.appleScriptFailed(text)), text)
        }
        let endsWithTheCode = ["Can’t get window id 5. (-1728)", "6:14: execution error: Invalid index. (-1719)\n",
                               "Safari發生錯誤：無法取得「window id 999999」。 (-1728)",
                               // A body with parentheses of its own: the code is the LAST group.
                               "x (y) (-1719)", "Can’t get first tab whose URL contains \"https://x.example/X_(Y)\". (-1728)"]
        for text in endsWithTheCode {
            XCTAssertTrue(SafariBridge.isObjectNotFound(text), text)
            XCTAssertTrue(SafariBridge.isTargetDangleError(.appleScriptFailed(text)), text)
        }
        // The guard sentinel has no code by design and still counts as a dangle.
        XCTAssertTrue(SafariBridge.isTargetDangleError(.appleScriptFailed("SB_TARGET_CHANGED")))
        // A page can throw any text it likes; a code-shaped tail in it is not the
        // error number. The JavaScript-error exclusion is what stops it here.
        XCTAssertFalse(SafariBridge.isTargetDangleError(.appleScriptFailed("JavaScript error: boom (-1728)")))
    }

    func testMalformedTextsHaveNoCode() {
        for text in ["", "()", "(", ")", "x)", "(x)", "abc (12", "no code here", "x (y)", "x (-)",
                     "x (99999999999999999999999)", "x (1 2)"] {
            XCTAssertNil(SafariBridge.appleScriptErrorCode(in: text), text)
            XCTAssertFalse(SafariBridge.isObjectNotFound(text), text)
        }
        XCTAssertEqual(SafariBridge.appleScriptErrorCode(in: "x (y) (-1719)"), -1719)
        XCTAssertEqual(SafariBridge.appleScriptErrorCode(in: "  Invalid index. (-1719) \n"), -1719)
    }

    func testATextThatOnlyMentionsTheCodeIsNotTranslatedToDocumentNotFound() async throws {
        // The translation site itself, not just the predicate: the same text
        // that must not pass for a not-found in `isObjectNotFound`.
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    if source.contains("set windowCount to count of windows") { return "" }
                    throw SafariBrowserError.appleScriptFailed("Can’t make -1719 into type text (-1700)")
                }) {
                    try await SafariBridge.getCurrentURL(target: .windowIndex(2))
                }
            }
            XCTFail("the runner throws")
        } catch SafariBrowserError.appleScriptFailed {
        } catch {
            XCTFail("expected the raw appleScriptFailed, got \(error)")
        }
    }

    // MARK: - The #79 bounded retry rides on the daemon-shaped error

    final class DispatchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    private func runDanglingJS(failingDispatches: Int) async throws -> (result: String, dispatches: Int) {
        let gs = "\u{1D}", rs = "\u{1E}"
        let listing = ["1", "2", "1", "https://w1.example/2", "Tab 2", "個人 — Tab 2", "101"].joined(separator: gs) + rs
        let dangling = SafariBrowserError.appleScriptFailed(
            "Safari got an error: Can’t get tab 2 of window id 101. Invalid index. (-1719)")
        let dispatches = DispatchCount()
        let target = SafariBridge.TargetDocument.resolvedTab(
            windowID: 101, tabInWindow: 2, rematch: .contains("w1.example/2"), profile: nil)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                if source.contains("set windowCount to count of windows") { return listing }
                if source.contains("do JavaScript") {
                    if dispatches.next() <= failingDispatches { throw dangling }
                    return "done"
                }
                return "ok"
            }) {
                try await SafariBridge.doJavaScript("1", target: target)
            }
        }
        return (result, dispatches.value)
    }

    func testADaemonShapedDanglingTargetIsRetriedOnce() async throws {
        let run = try await runDanglingJS(failingDispatches: 1)
        XCTAssertEqual(run.result, "done")
        XCTAssertEqual(run.dispatches, 2, "one failed dispatch, then exactly one retry")
    }

    func testASecondDanglingDispatchFailsClosedWithoutAThirdAttempt() async {
        do {
            _ = try await runDanglingJS(failingDispatches: 5)
            XCTFail("both dispatches dangle")
        } catch SafariBrowserError.targetTabChanged {
        } catch {
            XCTFail("expected targetTabChanged, got \(error)")
        }
    }

    func testADaemonShapedMissingWindowIsTranslatedToDocumentNotFound() async throws {
        // End to end through the bridge: the cached runner's error for a
        // missing window reaches runTargetedAppleScript's translation.
        let cache = PreCompiledScripts.CompileCache()
        // A request context of its own: without one the process-wide dialog
        // probe runs, which inspects the user's live Safari from a unit test.
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    if source.contains("set windowCount to count of windows") { return "" }
                    return try await DaemonDispatch.Handlers.cachedScriptText(
                        source: #"error "Can’t get window 2." number -1728"#, cache: cache)
                }) {
                    try await SafariBridge.getCurrentURL(target: .windowIndex(2))
                }
            }
            XCTFail("the window does not exist")
        } catch SafariBrowserError.documentNotFound {}
    }

    // MARK: - #170 verify R1: bounded capacity

    func testCompileCacheEvictsTheLeastRecentlyUsedScriptAtCapacity() async throws {
        // Every distinct source (window ids, JavaScript text) was kept for the
        // daemon's lifetime; the issue requires a bounded cache.
        let cache = PreCompiledScripts.CompileCache(capacity: 2)
        try await cache.compile(source: "return 1")
        try await cache.compile(source: "return 2")
        try await cache.compile(source: "return 1")           // most recently used again
        try await cache.compile(source: "return 3")
        let count = await cache.cacheCount
        XCTAssertEqual(count, 2)
        let keptRecent = await cache.contains(source: "return 1")
        let evictedOldest = await cache.contains(source: "return 2")
        XCTAssertTrue(keptRecent)
        XCTAssertFalse(evictedOldest)
    }

    func testDefaultCompileCacheCapacityIsBounded() {
        XCTAssertEqual(PreCompiledScripts.CompileCache.defaultCapacity, 256)
    }

    func testTheDaemonsDefaultCacheEvictsAtTheBound() async throws {
        // The daemon builds `CompileCache()`; the constant alone would pass with
        // an initializer that ignored it. 257 distinct sources: the first goes.
        let cache = PreCompiledScripts.CompileCache()
        for index in 0...256 { try await cache.compile(source: "return \(index)") }
        let count = await cache.cacheCount
        let oldest = await cache.contains(source: "return 0")
        let newest = await cache.contains(source: "return 256")
        XCTAssertEqual(count, 256)
        XCTAssertFalse(oldest)
        XCTAssertTrue(newest)
    }

    /// The test above builds its own cache; this one ties it to the daemon's. The daemon's server must
    /// construct its cache with the default capacity: a literal `capacity:` argument there (an unbounded
    /// cache, say) would pass every other test.
    func testTheDaemonServerBuildsItsCacheWithTheDefaultCapacity() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/SafariBrowser/Daemon/DaemonServeLoop.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let constructions = source.components(separatedBy: "PreCompiledScripts.CompileCache(").dropFirst()
        XCTAssertEqual(constructions.count, 1, "the daemon server builds exactly one compile cache")
        XCTAssertTrue(constructions.first?.hasPrefix(")") == true,
                      "and builds it without a capacity argument, so the default bound applies")
    }
}
