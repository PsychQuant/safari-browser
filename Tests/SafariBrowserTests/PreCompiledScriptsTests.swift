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
}

