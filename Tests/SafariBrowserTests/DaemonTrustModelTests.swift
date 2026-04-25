import XCTest
import ArgumentParser
@testable import SafariBrowser

/// Section 2 of `daemon-security-hardening` — regression guard for the
/// "IPC trust model — filesystem permissions only" requirement. The
/// daemon's transport SHALL be a Unix-domain socket only; no TCP,
/// no Linux abstract namespace. This test asserts that any future
/// contribution attempting to add `--listen-tcp` or `--socket-path @...`
/// flags would fail at CLI parse time. Today those flags don't exist,
/// so ArgumentParser rejects them as unknown options — this test
/// codifies that behavior so removal of the test (or addition of the
/// flags) requires a corresponding spec amendment.
final class DaemonTrustModelTests: XCTestCase {

    func testListenTcpFlagRejectedAtParseTime() {
        // ArgumentParser's parsing should reject unknown options. Use
        // the public DaemonCommand.parseAsRoot path to exercise the
        // exact CLI surface end users hit.
        XCTAssertThrowsError(
            try DaemonCommand.parseAsRoot(["start", "--listen-tcp", "0.0.0.0:9000"])
        ) { error in
            // Could be `UnknownArgument` or similar — what matters is
            // that parsing failed. Document the error type for future
            // contributors.
            let msg = "\(error)"
            XCTAssertTrue(
                msg.contains("listen-tcp") || msg.contains("Unknown") || msg.contains("unrecognized"),
                "expected parse error mentioning the rejected flag, got: \(msg)"
            )
        }
    }

    func testAbstractSocketPathRejectedAtParseTime() {
        // Linux abstract-namespace sockets (`@my-socket`) bypass filesystem
        // permissions entirely — any local user could connect. macOS does
        // not implement abstract namespace, but a future cross-platform
        // contributor might add it.
        XCTAssertThrowsError(
            try DaemonCommand.parseAsRoot(["start", "--socket-path", "@my-socket"])
        ) { error in
            let msg = "\(error)"
            XCTAssertTrue(
                msg.contains("socket-path") || msg.contains("Unknown") || msg.contains("unrecognized"),
                "expected parse error mentioning the rejected flag, got: \(msg)"
            )
        }
    }

    func testHostPortStyleSocketRejected() {
        // `tcp://host:port` URI syntax sometimes used by daemon CLIs.
        XCTAssertThrowsError(
            try DaemonCommand.parseAsRoot(["start", "--listen", "tcp://localhost:8080"])
        )
    }
}
