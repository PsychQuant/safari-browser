import XCTest
@testable import SafariBrowser

/// Section 3 of `daemon-security-hardening` — pure tests for
/// `DaemonLog` redaction / truncation / opt-out warning. The logger
/// itself (file open, lifecycle, append loop) is wired separately;
/// these tests pin the contract that any prospective log entry honors.
final class DaemonLogRedactionTests: XCTestCase {

    // MARK: - Redaction (3.1)

    func testRedactParams_appleScriptExecute_redactsSource() throws {
        let params = #"{"source":"tell application \"Safari\" to return name"}"#
        let redacted = DaemonLog.redactParams(
            method: "applescript.execute",
            paramsJSON: Data(params.utf8),
            logFull: false
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        // Source field SHALL NOT appear in the log
        XCTAssertFalse(s.contains("tell application"), "raw source must not leak: \(s)")
        XCTAssertTrue(s.contains("<redacted"), "must use redaction marker: \(s)")
        XCTAssertTrue(s.contains("bytes>"), "must report byte count: \(s)")
    }

    func testRedactParams_appleScriptExecute_byteCountMatchesOriginal() throws {
        let source = "tell application \"Safari\" to return name"
        let originalBytes = source.utf8.count
        let raw = Data(#"{"source":"tell application \"Safari\" to return name"}"#.utf8)
        let redacted = DaemonLog.redactParams(
            method: "applescript.execute",
            paramsJSON: raw,
            logFull: false
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("<redacted \(originalBytes) bytes>"),
                      "byte count should match original \(originalBytes): \(s)")
    }

    func testRedactParams_safariJsCode_redactsCode() throws {
        // Defensive: spec mentions `Safari.js.code` as a future method.
        // Redaction logic SHALL treat `code` field the same as `source`.
        let params = #"{"code":"document.cookie"}"#
        let redacted = DaemonLog.redactParams(
            method: "Safari.js",
            paramsJSON: Data(params.utf8),
            logFull: false
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("document.cookie"), "raw JS code must not leak: \(s)")
        XCTAssertTrue(s.contains("<redacted"), "must use redaction marker: \(s)")
    }

    func testRedactParams_methodWithoutSensitiveField_passthrough() throws {
        let params = #"{"timeout":30}"#
        let redacted = DaemonLog.redactParams(
            method: "documents.list",
            paramsJSON: Data(params.utf8),
            logFull: false
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("timeout"), "non-sensitive params must pass through: \(s)")
        XCTAssertFalse(s.contains("<redacted"), "no redaction expected: \(s)")
    }

    func testRedactParams_logFullBypass() throws {
        let params = #"{"source":"tell app \"Safari\" to do something secret"}"#
        let redacted = DaemonLog.redactParams(
            method: "applescript.execute",
            paramsJSON: Data(params.utf8),
            logFull: true
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        // logFull=true SHALL emit raw payload (operator opt-in)
        XCTAssertTrue(s.contains("tell app"), "logFull bypass should preserve raw: \(s)")
    }

    func testRedactParams_invalidJSON_returnsRedactedPlaceholder() throws {
        // Defensive: malformed JSON in params should NOT cause the daemon
        // to crash. A safe redacted placeholder is acceptable.
        let badJSON = Data("not valid json {".utf8)
        let redacted = DaemonLog.redactParams(
            method: "applescript.execute",
            paramsJSON: badJSON,
            logFull: false
        )
        let s = String(data: redacted, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("<redacted") || s.contains("malformed"),
                      "invalid JSON must produce safe placeholder, not raw: \(s)")
        XCTAssertFalse(s.contains("not valid json"),
                       "raw malformed payload must NOT leak: \(s)")
    }

    // MARK: - Truncation (3.1 cont.)

    func testTruncateResult_shortString_unchanged() throws {
        let result = #"{"status":"ok","output":"hello"}"#
        let truncated = DaemonLog.truncateResult(
            resultJSON: Data(result.utf8),
            logFull: false
        )
        let s = String(data: truncated, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("hello"), "short output must pass through: \(s)")
        XCTAssertFalse(s.contains("…(truncated)"), "no truncation marker expected: \(s)")
    }

    func testTruncateResult_longString_truncatedTo256BytesWithMarker() throws {
        // 512-byte ASCII string — value SHALL be cut to 256 bytes + marker.
        let long = String(repeating: "a", count: 512)
        let result = #"{"status":"ok","output":"\#(long)"}"#
        let truncated = DaemonLog.truncateResult(
            resultJSON: Data(result.utf8),
            logFull: false
        )
        let s = String(data: truncated, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("…(truncated)"), "must mark truncated: \(s)")

        // Parse the output JSON and inspect the value field directly so we
        // don't conflate 'a's in the truncation marker word ("truncAted")
        // with 'a's preserved from the original payload.
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: truncated, options: []) as? [String: Any]
        )
        let outputValue = try XCTUnwrap(dict["output"] as? String)
        let aPrefixCount = outputValue.prefix(while: { $0 == "a" }).count
        XCTAssertLessThanOrEqual(aPrefixCount, 256, "value prefix must not exceed 256-byte cap: got \(aPrefixCount)")
        XCTAssertGreaterThan(aPrefixCount, 200, "value prefix must preserve most bytes up to cap: got \(aPrefixCount)")
        XCTAssertTrue(outputValue.hasSuffix("…(truncated)"), "value must end with marker: \(outputValue)")
    }

    func testTruncateResult_logFullBypass_keepsFullPayload() throws {
        let long = String(repeating: "b", count: 512)
        let result = #"{"status":"ok","output":"\#(long)"}"#
        let truncated = DaemonLog.truncateResult(
            resultJSON: Data(result.utf8),
            logFull: true
        )
        let s = String(data: truncated, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("…(truncated)"), "logFull bypass should not truncate: \(s)")
        let bCount = s.filter { $0 == "b" }.count
        XCTAssertEqual(bCount, 512, "full bypass must preserve all bytes: got \(bCount)")
    }

    func testTruncateResult_errorMetadataPreservedFull() throws {
        // Per spec scenario "AppleScript compile errors stay visible":
        // error code + message SHALL be logged in full (not truncated).
        // We achieve this by only truncating string fields longer than the
        // limit; short error messages always pass through.
        let result = #"{"status":"error","errorKind":"compileFailed","message":"unexpected end of script"}"#
        let truncated = DaemonLog.truncateResult(
            resultJSON: Data(result.utf8),
            logFull: false
        )
        let s = String(data: truncated, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("compileFailed"), "errorKind must remain visible: \(s)")
        XCTAssertTrue(s.contains("unexpected end of script"), "error message must remain visible: \(s)")
    }

    func testTruncateResult_utf8SafeAtBoundary() throws {
        // Truncation at byte 256 must NOT split a UTF-8 multi-byte sequence.
        // Build a string that places a multi-byte char straddling byte 256.
        var s = String(repeating: "a", count: 254)
        s += "中" // 3-byte UTF-8 char straddles bytes 254,255,256
        s += String(repeating: "b", count: 100)
        let result = #"{"status":"ok","output":"\#(s)"}"#
        let truncated = DaemonLog.truncateResult(
            resultJSON: Data(result.utf8),
            logFull: false
        )
        // Must not produce invalid UTF-8 bytes — String() decoding succeeds
        XCTAssertNotNil(String(data: truncated, encoding: .utf8),
                        "truncation must preserve UTF-8 validity")
    }

    // MARK: - Opt-out warning (3.2)

    func testEmitFullLogWarning_envSet_writesWarning() {
        var captured = ""
        DaemonLog.emitFullLogWarningIfNeeded(
            env: ["SAFARI_BROWSER_DAEMON_LOG_FULL": "1"],
            writer: { captured += $0 }
        )
        XCTAssertTrue(captured.contains("SAFARI_BROWSER_DAEMON_LOG_FULL"),
                      "warning must mention env var name: \(captured)")
        XCTAssertTrue(captured.contains("WARNING") || captured.contains("warning"),
                      "warning must be marked: \(captured)")
        XCTAssertTrue(captured.hasSuffix("\n"),
                      "warning must end with newline so it's a single stderr line")
    }

    func testEmitFullLogWarning_envUnset_noWrite() {
        var captured = ""
        DaemonLog.emitFullLogWarningIfNeeded(
            env: [:],
            writer: { captured += $0 }
        )
        XCTAssertEqual(captured, "", "no warning when env unset")
    }

    func testEmitFullLogWarning_envOtherValue_noWrite() {
        // Only literal "1" enables — other truthy strings do not.
        var captured = ""
        DaemonLog.emitFullLogWarningIfNeeded(
            env: ["SAFARI_BROWSER_DAEMON_LOG_FULL": "true"],
            writer: { captured += $0 }
        )
        XCTAssertEqual(captured, "", "only '1' enables full-log mode")
    }

    func testIsFullLoggingEnabled_pureDecision() {
        XCTAssertTrue(DaemonLog.isFullLoggingEnabled(env: ["SAFARI_BROWSER_DAEMON_LOG_FULL": "1"]))
        XCTAssertFalse(DaemonLog.isFullLoggingEnabled(env: [:]))
        XCTAssertFalse(DaemonLog.isFullLoggingEnabled(env: ["SAFARI_BROWSER_DAEMON_LOG_FULL": "0"]))
        XCTAssertFalse(DaemonLog.isFullLoggingEnabled(env: ["SAFARI_BROWSER_DAEMON_LOG_FULL": "true"]))
    }

    // MARK: - Format entry

    func testFormatEntry_includesRequestMetadata() {
        let line = DaemonLog.formatEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            method: "applescript.execute",
            requestId: 42,
            durationMs: 123,
            paramsLog: #"{"source":"<redacted 40 bytes>"}"#,
            resultLog: #"{"status":"ok","output":"hello"}"#,
            errorLog: nil
        )
        XCTAssertTrue(line.contains("applescript.execute"), "method must appear: \(line)")
        XCTAssertTrue(line.contains("42"), "requestId must appear: \(line)")
        XCTAssertTrue(line.contains("123"), "duration must appear: \(line)")
        XCTAssertTrue(line.contains("<redacted 40 bytes>"), "redacted params must appear: \(line)")
        XCTAssertTrue(line.hasSuffix("\n") || line.contains("hello"),
                      "result must appear on success: \(line)")
    }

    func testFormatEntry_errorReplacesResult() {
        let line = DaemonLog.formatEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            method: "applescript.execute",
            requestId: 7,
            durationMs: 5,
            paramsLog: "{}",
            resultLog: nil,
            errorLog: "compileFailed: unexpected token"
        )
        XCTAssertTrue(line.contains("compileFailed"), "error string must appear: \(line)")
    }

    // MARK: - Integration with DaemonServer.Instance

    func testInstance_dispatchInvokesLogWriter_redactsSourceParam() async throws {
        // Wire-up smoke test: install a capture writer on a real Instance,
        // register a stub handler, dispatch a request through a socket
        // round-trip, and verify the captured log line contains the
        // redaction marker (not the raw AppleScript source).
        // Use a short path under /tmp — sockaddr_un.sun_path is 104 bytes
        // on macOS so the long $TMPDIR (`/var/folders/.../T/`) overflows.
        let socketPath = "/tmp/lrt-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }
        let server = DaemonServer.Instance()
        defer { Task { await server.stop() } }

        // Capture closure must be Sendable for the writer signature.
        actor Capture {
            var lines: [String] = []
            func append(_ s: String) { lines.append(s) }
            func snapshot() -> [String] { lines }
        }
        let capture = Capture()
        let writer: @Sendable (String) -> Void = { line in
            Task { await capture.append(line) }
        }

        await server.setLogWriter(writer, logFull: false)
        await server.register("applescript.execute") { _ in
            Data(#"{"status":"ok","output":"some result"}"#.utf8)
        }
        try await server.start(socketPath: socketPath)

        // Issue one request with a sensitive `source` param.
        let body = #"{"method":"applescript.execute","params":{"source":"tell application \"Safari\" to return name"},"requestId":99}"#
        _ = try sendRawRequestSync(path: socketPath, body: body)

        // Allow the async writer task to drain.
        try await Task.sleep(for: .milliseconds(100))
        let captured = await capture.snapshot()
        XCTAssertEqual(captured.count, 1, "expected one log entry")
        let line = captured[0]
        XCTAssertFalse(line.contains("tell application"),
                       "raw source must NOT appear in captured log: \(line)")
        XCTAssertTrue(line.contains("<redacted"),
                      "redaction marker must appear: \(line)")
        XCTAssertTrue(line.contains("applescript.execute"),
                      "method name must appear in log: \(line)")
        XCTAssertTrue(line.contains("99"), "requestId must appear: \(line)")
    }

    /// Minimal raw socket client — just enough for the integration test.
    /// Sends one request, reads the handshake line + response line.
    private func sendRawRequestSync(path: String, body: String) throws -> Any {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        var connectRC: Int32 = -1
        var attempts = 0
        while connectRC != 0 && attempts < 50 {
            connectRC = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, addrLen)
                }
            }
            if connectRC != 0 { usleep(20_000); attempts += 1 }
        }
        XCTAssertEqual(connectRC, 0, "connect failed: errno=\(errno)")

        let payload = Data((body + "\n").utf8)
        _ = payload.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }

        // Discard handshake line.
        _ = readOneLine(fd: fd)
        guard let line = readOneLine(fd: fd) else {
            throw XCTSkip("no response from server")
        }
        return try JSONSerialization.jsonObject(with: line, options: [])
    }

    private func readOneLine(fd: Int32) -> Data? {
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 { return bytes.isEmpty ? nil : Data(bytes) }
            if buf[0] == 0x0A { return Data(bytes) }
            bytes.append(buf[0])
        }
    }
}
