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
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "new-batch")
    }
}

private actor ScriptPage {
    private let context: JSContext
    private let interleave: Bool
    private var interleaved = false

    init(interleave: Bool) throws {
        guard let context = JSContext() else { throw CocoaError(.coderInvalidValue) }
        self.context = context
        self.interleave = interleave
        context.evaluateScript("var window = globalThis")
    }

    func didInterleave() -> Bool { interleaved }

    func run(_ source: String) throws -> String {
        guard let start = source.range(of: "do JavaScript \"") else {
            if source.contains("get id of window") { return "71" }
            if source.contains("URL of") { return "https://fixture.invalid/" }
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
        context.exception = nil
        let value = context.evaluateScript(js)
        // Safari do JavaScript swallows uncaught JS exceptions as empty text.
        let result = context.exception == nil && value?.isUndefined == false ? value?.toString() ?? "" : ""
        context.exception = nil
        if interleave && !interleaved && js.contains("window.__sbResult = '' + (") {
            // Another legitimate `js` invocation reaches its store step before
            // the first invocation reads its result; both payloads have length 9.
            context.evaluateScript(JSWrapper.expressionWrapper("'old-batch'"))
            interleaved = true
        }
        return result
    }
}
