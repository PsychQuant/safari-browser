import Foundation
import XCTest
@testable import SafariBrowser

/// #355: the daemon converts a result to AppleScript source form only when asked, and both the
/// socket handler and the in-process runner of `exec.runScript` give the same text as
/// `osascript -s s`. The scripts return literals; no Safari is involved.
final class SourceFormDaemonPathTests: XCTestCase {

    private static let listScript = #"return {1, "a\"b\\c" & (character id 30), missing value, {}}"#

    private func execute(_ params: [String: Any], cache: PreCompiledScripts.CompileCache) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let response = try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: data, cache: cache)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    func testTheHandlerConvertsToSourceFormWhenAsked() async throws {
        let response = try await execute(["source": Self.listScript, "resultForm": "sourceForm"],
                                         cache: PreCompiledScripts.CompileCache())
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(response["output"] as? String,
                       try AppleScriptSourceFormRenderTests.osascriptSourceForm(Self.listScript))
    }

    func testWithoutAResultFormTheHandlerKeepsReturningTheStringValue() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let text = try await execute(["source": #"return "a\"b""#], cache: cache)
        XCTAssertEqual(text["output"] as? String, "a\"b", "text stays unquoted, as before #355")
        let list = try await execute(["source": Self.listScript], cache: cache)
        XCTAssertEqual(list["output"] as? String, "", "a list's string value is nil, as before #355")
    }

    func testAnUnknownResultFormIsABadRequest() async throws {
        let response = try await execute(["source": "return 1", "resultForm": "bogus"],
                                         cache: PreCompiledScripts.CompileCache())
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["errorKind"] as? String, "badRequest")
        XCTAssertNil(response["output"])
    }

    func testAResultFormThatIsNotAStringIsABadRequest() async throws {
        let cache = PreCompiledScripts.CompileCache()
        for value in [true, 1, NSNull(), ["sourceForm"]] as [Any] {
            let response = try await execute(["source": "return 1", "resultForm": value], cache: cache)
            XCTAssertEqual(response["status"] as? String, "error", "\(value)")
            XCTAssertEqual(response["errorKind"] as? String, "badRequest", "\(value)")
        }
    }

    func testTheInProcessRunnersBothServeExecRunScript() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let expected = try AppleScriptSourceFormRenderTests.osascriptSourceForm(Self.listScript)
        let (sourceForm, text) = try await DaemonDispatch.withInProcessRunners(cache: cache) {
            (try await SafariBridge.runAppleScriptSourceForm(Self.listScript),
             try await SafariBridge.runAppleScript(#"return "a\"b""#))
        }
        XCTAssertEqual(sourceForm, expected)
        XCTAssertEqual(text, "a\"b")
    }

    func testAPlainRunnerAloneIsAskedForTheSourceFormText() async throws {
        // Test fakes install only `appleScriptRunner`; they answer with source form text themselves.
        let seen = SourceFormCallLog<[String]>([])
        let text = try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
            seen.mutate { $0.append(source) }
            return "{}"
        }) {
            try await SafariBridge.runAppleScriptSourceForm("return {}")
        }
        XCTAssertEqual(text, "{}")
        XCTAssertEqual(seen.value, ["return {}"])
    }

    func testTheStatelessPathAsksOsascriptForSourceForm() {
        XCTAssertEqual(SafariBridge.sourceFormOsascriptArguments("return {}"), ["-s", "s", "-e", "return {}"])
    }
}

/// Minimal thread-safe box for observing calls from `@Sendable` closures.
private final class SourceFormCallLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
