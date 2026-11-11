import XCTest
@testable import SafariBrowser

/// #355: the daemon converts an `NSAppleEventDescriptor` into the same source form the stateless
/// path gets from `osascript -s s`. The oracle here is the real `osascript` (no Safari involved:
/// every script returns literals), so a change in Apple's output format fails these tests instead
/// of making the two paths decode differently.
final class AppleScriptSourceFormRenderTests: XCTestCase {

    /// `osascript -s s -e <script>` stdout, without its final newline.
    static func osascriptSourceForm(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-s", "s", "-e", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "osascript failed", file: file, line: line)
        var text = try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The daemon side: run with `NSAppleScript`, convert the descriptor.
    static func renderedSourceForm(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let compiled = try XCTUnwrap(NSAppleScript(source: script), file: file, line: line)
        var error: NSDictionary?
        let descriptor = compiled.executeAndReturnError(&error)
        XCTAssertNil(error, "NSAppleScript failed: \(String(describing: error))", file: file, line: line)
        return AppleScriptSourceForm.render(descriptor)
    }

    /// AppleScript text holding exactly these UTF-16 units (big-endian `utxt` data), including
    /// unpaired surrogates that `character id` refuses to build.
    static func utxt(_ units: [UInt16]) -> String {
        // `«data utxt»` with no bytes does not compile; the empty string is just `""`.
        units.isEmpty ? "\"\"" : "(«data utxt\(units.map { String(format: "%04X", $0) }.joined())» as Unicode text)"
    }

    private func assertSameOnBothPaths(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let stateless = try Self.osascriptSourceForm(script, file: file, line: line)
        let daemon = try Self.renderedSourceForm(script, file: file, line: line)
        XCTAssertEqual(Array(daemon.utf8), Array(stateless.utf8),
                       "renderer differs from osascript -s s:\n\(daemon.prefix(300).debugDescription)\n\(stateless.prefix(300).debugDescription)",
                       file: file, line: line)
    }

    func testListsIntegersAndMissingValueMatchOsascript() throws {
        try assertSameOnBothPaths(#"return {{1, -2, "a", missing value}, {}, {{}}, 0, 536870911}"#)
    }

    func testEveryBMPCharacterMatchesOsascriptAndRoundTrips() throws {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for unit in 0...0xFFFF where !(0xD800...0xDFFF).contains(unit) {
            current.append(UInt16(unit))
            if current.count == 4096 { chunks.append(current); current = [] }
        }
        chunks.append(current)
        let extras = [
            "😀👍🏽👨‍👩‍👧\u{10FFFF}\u{1F1F9}\u{1F1FC}\u{E0041}\u{E007F}",
            "\"\u{0301}\\\u{0301}\u{1D}\u{0301}\u{1E}\u{FE0F}",
            "x" + String(repeating: "\u{0301}", count: 1000) + "\"",
            "\r\n\t\u{0}",
        ]
        chunks += extras.map { Array($0.utf16) }
        let script = "return {" + chunks.map(Self.utxt).joined(separator: ", ") + "}"
        try assertSameOnBothPaths(script)

        guard case .list(let items) = try AppleScriptSourceForm.parse(try Self.osascriptSourceForm(script)) else {
            return XCTFail("not a list")
        }
        XCTAssertEqual(items.count, chunks.count)
        for (item, chunk) in zip(items, chunks) {
            guard case .text(let text) = item else { return XCTFail("not text") }
            XCTAssertEqual(Array(text.utf16), chunk)
        }
    }

    /// osascript splits a string at each `"` and `\` and cuts each part at its first unpaired
    /// surrogate (measured against 3,000 random strings; design.md). The table is the spec's example.
    func testUnpairedSurrogatesAreCutPerRunAsOsascriptDoes() throws {
        let cases: [([UInt16], String)] = [
            ([0x41, 0xD83D, 0x42], #""A""#),
            ([0x22, 0xD83D, 0x22], #""\"\"""#),
            ([0x41, 0xD83D, 0xDE00, 0x42, 0xD800], #""A😀B""#),
            ([0xDC00, 0x42], #""""#),
            ([0x5C, 0xDC00, 0x41, 0x5C, 0x42], #""\\\\B""#),
        ]
        for (units, expected) in cases {
            let script = "return \(Self.utxt(units))"
            XCTAssertEqual(try Self.osascriptSourceForm(script), expected, "osascript, \(units)")
            XCTAssertEqual(try Self.renderedSourceForm(script), expected, "renderer, \(units)")
        }
    }

    func testRandomStringsWithUnpairedSurrogatesMatchOsascript() throws {
        var generator = SplitMix64(seed: 355)
        let alphabet: [[UInt16]] = [[0x41], [0x42], [0x22], [0x5C], [0xD83D], [0xDC00],
                                    [0xD83D, 0xDE00], [0x0301], [0x1E], [0x0A]]
        var strings: [[UInt16]] = []
        for _ in 0..<200 {
            var units: [UInt16] = []
            for _ in 0..<(1 + Int(generator.next() % 12)) {
                units += alphabet[Int(generator.next() % UInt64(alphabet.count))]
            }
            strings.append(units)
        }
        try assertSameOnBothPaths("return {" + strings.map(Self.utxt).joined(separator: ", ") + "}")
    }

    func testOtherValueKindsDecodeAlikeOnBothPaths() throws {
        // Reals and booleans are printed differently by the two paths, but both decode to `.other`,
        // so an enumeration that carried one fails the same way on either path. (Records are not
        // covered: the enumeration script builds only lists, so none can arrive.)
        let script = "return {3.5, 2147483647, true, false}"
        let stateless = try AppleScriptSourceForm.parse(try Self.osascriptSourceForm(script))
        let daemon = try AppleScriptSourceForm.parse(try Self.renderedSourceForm(script))
        XCTAssertEqual(stateless, .list([.real, .real, .other, .other]))
        XCTAssertEqual(daemon, stateless)
    }
}
