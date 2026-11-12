import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

/// #355: `runAppleScriptSourceForm` end to end, without any in-process runner — real `osascript`
/// on the stateless path, and a real daemon instance on a socket for the daemon path. The scripts
/// return literals; no Safari is involved.
final class SourceFormEndToEndTests: XCTestCase {

    private static let script = #"return {1, "a\"b\\c" & (character id 30), missing value}"#

    /// Point name resolution at a fresh NAME (so no running daemon of this machine is reached) and
    /// set or clear `SAFARI_BROWSER_DAEMON`, restoring both afterwards.
    private func withDaemonEnvironment<T>(name: String, daemon: Bool, _ body: () async throws -> T) async throws -> T {
        let keys = ["SAFARI_BROWSER_NAME", "SAFARI_BROWSER_DAEMON"]
        let saved: [(String, String?)] = keys.map { key in (key, ProcessInfo.processInfo.environment[key]) }
        setenv("SAFARI_BROWSER_NAME", name, 1)
        if daemon { setenv("SAFARI_BROWSER_DAEMON", "1", 1) } else { unsetenv("SAFARI_BROWSER_DAEMON") }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return try await body()
    }

    func testTheStatelessPathRunsOsascriptInSourceForm() async throws {
        let name = "sf355-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(FileManager.default.fileExists(atPath: DaemonClient.socketPath(name: name)))
        let text = try await withDaemonEnvironment(name: name, daemon: false) {
            try await SafariBridge.runAppleScriptSourceForm(Self.script)
        }
        XCTAssertEqual(text, try AppleScriptSourceFormRenderTests.osascriptSourceForm(Self.script))
        XCTAssertEqual(try AppleScriptSourceForm.parse(text),
                       .list([.integer(1), .text("a\"b\\c\u{1E}"), .missingValue]))
    }

    func testTheDaemonPathAsksTheDaemonForSourceForm() async throws {
        let name = "sf355-\(UUID().uuidString.prefix(8))"
        let socketPath = DaemonClient.socketPath(name: name)
        let server = DaemonServer.Instance()
        await DaemonDispatch.registerPhase1Handlers(on: server, cache: PreCompiledScripts.CompileCache())
        try await server.start(socketPath: socketPath)
        defer { unlink(socketPath) }
        do {
            let (direct, routed) = try await withDaemonEnvironment(name: name, daemon: true) {
                (try await SafariBridge.executeAppleScriptViaDaemon(source: Self.script, timeout: 10, sourceForm: true),
                 try await SafariBridge.runAppleScriptSourceForm(Self.script))
            }
            let expected = try AppleScriptSourceFormRenderTests.osascriptSourceForm(Self.script)
            XCTAssertEqual(direct, expected, "executeAppleScriptViaDaemon(sourceForm: true)")
            XCTAssertEqual(routed, expected, "runAppleScriptSourceForm through the router")
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    /// Not a proof: `exec.runScript` runs steps that can enumerate windows, and must get both
    /// in-process runners. A behavioural test would need Safari, so this pins the registration's
    /// shape; `SourceFormDaemonPathTests` checks what `withInProcessRunners` installs.
    func testExecRunScriptIsRegisteredWithBothInProcessRunners() throws {
        let dispatch = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SafariBrowser/Daemon/DaemonDispatch.swift"),
            encoding: .utf8)
        guard let registration = dispatch.range(of: #"server.register("exec.runScript")"#) else {
            return XCTFail("exec.runScript registration not found")
        }
        let body = dispatch[registration.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("withInProcessRunners(cache: cache)"),
                      "exec.runScript must run inside withInProcessRunners: \(body)")
        XCTAssertFalse(body.contains("$appleScriptRunner.withValue"),
                       "exec.runScript must not install the text runner alone: \(body)")
    }

    /// A daemon serving this protocol, optionally without the source form capability (a daemon from
    /// before #355 does not announce it), whose `applescript.execute` and `exec.runScript` calls are
    /// counted. `exec.runScript` answers an empty result list.
    private final class CountingDaemon: @unchecked Sendable {
        let name = "sf355-\(UUID().uuidString.prefix(8))"
        var socketPath: String { DaemonClient.socketPath(name: name) }
        let server: DaemonServer.Instance
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[method, default: 0] }
        private func bump(_ method: String) { lock.lock(); defer { lock.unlock() }; counts[method, default: 0] += 1 }

        init(capabilities: [String], output: String? = nil) async throws {
            server = DaemonServer.Instance(capabilities: capabilities)
            let cache = PreCompiledScripts.CompileCache()
            await server.register("applescript.execute") { [self] params in
                self.bump("applescript.execute")
                if let output {
                    return try JSONSerialization.data(withJSONObject: ["status": "ok", "output": output])
                }
                return try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: params, cache: cache)
            }
            await server.register("exec.runScript") { [self] _ in
                self.bump("exec.runScript")
                return try JSONSerialization.data(withJSONObject: ["results": "[]"])
            }
            try await server.start(socketPath: socketPath)
        }

        func stop() async {
            await server.stop()
            unlink(socketPath)
        }
    }

    func testTheHandshakeAnnouncesTheSourceFormCapability() throws {
        let announced = try XCTUnwrap(DaemonProtocol.decodeHandshake(DaemonProtocol.encodeHandshake(
            maxRequestLineBytes: 1024, capabilities: DaemonProtocol.serverCapabilities)))
        XCTAssertTrue(announced.capabilities.contains(DaemonProtocol.Capability.sourceForm.rawValue))
        let legacy = try XCTUnwrap(DaemonProtocol.decodeHandshake(DaemonProtocol.encodeHandshake(maxRequestLineBytes: 1024)))
        XCTAssertTrue(legacy.capabilities.isEmpty, "a handshake without the field announces nothing")
        // The old version decoder still reads a handshake that carries the field.
        XCTAssertNotNil(DaemonProtocol.decodeHandshakeVersion(DaemonProtocol.encodeHandshake(
            capabilities: DaemonProtocol.serverCapabilities)))
        for invalid in [#""sourceForm""#, "true", "[1]", "null"] {
            let line = #"{"protocol":{"version":{"semver":"2.1.3","commit":"abc","dirty":false,"vendor":"git"},"capabilities":"# + invalid + "}}"
            XCTAssertNil(DaemonProtocol.decodeHandshake(Data(line.utf8)), invalid)
        }
    }

    /// An unstamped daemon from before #355 matches an unstamped client in the handshake (#320) but
    /// does not announce the source form capability. The client checks before sending: no request
    /// reaches that daemon, one `[daemon fallback: …]` line names it, and the enumeration runs on
    /// the stateless path.
    func testADaemonWithoutTheCapabilityIsNotAskedAndTheStatelessPathRuns() async throws {
        let daemon = try await CountingDaemon(capabilities: [])
        let warnings = WarningLog()
        let text: String
        do {
            text = try await withDaemonEnvironment(name: daemon.name, daemon: true) {
                try await SafariBridge.runAppleScriptSourceForm(Self.script, warnWriter: { warnings.append($0) })
            }
        } catch {
            await daemon.stop()
            throw error
        }
        await daemon.stop()
        XCTAssertEqual(text, try AppleScriptSourceFormRenderTests.osascriptSourceForm(Self.script))
        XCTAssertEqual(daemon.count("applescript.execute"), 0, "the check happens before sending")
        XCTAssertEqual(warnings.lines.count, 1, "\(warnings.lines)")
        let line = warnings.lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("[daemon fallback: "), line)
        XCTAssertTrue(line.contains("predates") && line.contains("safari-browser daemon stop"), line)
        // Nothing starts a daemon on its own after `daemon stop` (#355 verify round 4).
        XCTAssertTrue(line.contains("safari-browser daemon start"), line)
    }

    /// A daemon that announced the capability is asked; an empty answer from it is not rerun
    /// anywhere: it reaches the decoder and fails the enumeration.
    func testAnEmptyAnswerFromACapableDaemonIsAnErrorNotARerun() async throws {
        let daemon = try await CountingDaemon(capabilities: DaemonProtocol.serverCapabilities, output: "")
        let warnings = WarningLog()
        do {
            _ = try await withDaemonEnvironment(name: daemon.name, daemon: true) {
                try await DaemonRequestContext.$current.withValue(DaemonRequestContext(probe: { _ in .clear }, environment: [:])) {
                    try await SafariBridge.decodeWindowEnumeration(
                        try await SafariBridge.runAppleScriptSourceForm("return {}", warnWriter: { warnings.append($0) }))
                }
            }
            XCTFail("an empty source form answer must not decode")
        } catch SafariBrowserError.windowEnumerationCorrupt {
        } catch {
            await daemon.stop()
            throw error
        }
        await daemon.stop()
        XCTAssertEqual(daemon.count("applescript.execute"), 1)
        XCTAssertEqual(warnings.lines, [], "no fallback line: nothing was rerun")
    }

    /// `exec` hands a whole script to the daemon's `exec.runScript`, which enumerates windows with
    /// the daemon's own code. A daemon without the capability would run the old enumeration, so the
    /// script is not sent: one fallback line, and the per-step path runs it instead.
    func testExecDoesNotSendAScriptToADaemonWithoutTheCapability() async throws {
        for (capabilities, expectSent) in [([String](), false), (DaemonProtocol.serverCapabilities, true)] {
            let daemon = try await CountingDaemon(capabilities: capabilities)
            let notes = WarningLog()
            let command = try ExecCommand.parse([])
            let result: String?
            do {
                result = try await withDaemonEnvironment(name: daemon.name, daemon: true) {
                    try await command.runViaDaemon(steps: [], note: { notes.append($0) })
                }
            } catch {
                await daemon.stop()
                throw error
            }
            await daemon.stop()
            if expectSent {
                XCTAssertEqual(result, "[]")
                XCTAssertEqual(daemon.count("exec.runScript"), 1)
                XCTAssertEqual(notes.lines, [])
            } else {
                XCTAssertNil(result, "nil hands the script to the per-step path")
                XCTAssertEqual(daemon.count("exec.runScript"), 0)
                XCTAssertEqual(notes.lines.count, 1, "\(notes.lines)")
                XCTAssertTrue((notes.lines.first ?? "").contains("safari-browser daemon stop"), "\(notes.lines)")
                XCTAssertTrue((notes.lines.first ?? "").contains("safari-browser daemon start"), "\(notes.lines)")
            }
        }
    }

    /// Raw data values: `osascript -s s` prints `«data utf8…»` / `«data TEXT…»`, which parse as
    /// `.other`; the daemon conversion must not turn them into text (#355 verify round 2).
    func testRawTextDataIsOpaqueOnBothPaths() throws {
        let script = "return {«data utf800610062», «data TEXT6162»}"
        let stateless = try AppleScriptSourceForm.parse(try AppleScriptSourceFormRenderTests.osascriptSourceForm(script))
        let daemon = try AppleScriptSourceForm.parse(try AppleScriptSourceFormRenderTests.renderedSourceForm(script))
        XCTAssertEqual(stateless, .list([.other, .other]))
        XCTAssertEqual(daemon, stateless)
    }
}

private final class WarningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; stored.append(line) }
}
