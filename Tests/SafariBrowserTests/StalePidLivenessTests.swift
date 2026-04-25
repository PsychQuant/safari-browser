import XCTest
import Foundation
@testable import SafariBrowser

/// Section 4 of `daemon-security-hardening` — stale-pid liveness
/// detection. The daemon's pid file SHALL embed enough metadata that a
/// recycled pid (kernel reused N for an unrelated process) or a
/// completely different binary running at the same pid is correctly
/// identified as stale, so `daemon start` does not abort against a
/// "live" daemon that is actually a CI runner / Slack helper / etc.
final class StalePidLivenessTests: XCTestCase {

    // MARK: - PidRecord round-trip (4.1)

    func testPidRecord_writeRead_roundTrip() throws {
        let path = "/tmp/sb-pid-rt-\(UUID().uuidString.prefix(8)).pid"
        defer { unlink(path) }
        let record = DaemonPaths.PidRecord(
            pid: 4242,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.5
        )
        try DaemonPaths.writePidFile(record: record, at: path)

        switch DaemonPaths.readPidFile(at: path) {
        case .ok(let read):
            XCTAssertEqual(read, record)
        case .stale, .absent:
            XCTFail("expected .ok, got something else")
        }
    }

    func testPidRecord_writeUsesMode0600() throws {
        let path = "/tmp/sb-pid-mode-\(UUID().uuidString.prefix(8)).pid"
        defer { unlink(path) }
        let record = DaemonPaths.PidRecord(pid: 1, exec: "/x", boot: 1.0)
        try DaemonPaths.writePidFile(record: record, at: path)

        var sb = Darwin.stat()
        let rc = path.withCString { stat($0, &sb) }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(sb.st_mode & 0o777, 0o600,
                       "pid file mode must be 0600 (security-hardening 1.4)")
    }

    func testReadPidFile_absent_returnsAbsent() {
        let path = "/tmp/sb-pid-nope-\(UUID().uuidString.prefix(8)).pid"
        let result = DaemonPaths.readPidFile(at: path)
        XCTAssertEqual(result, .absent)
    }

    func testReadPidFile_oldSingleIntegerFormat_returnsStale() throws {
        // Forward compatibility: pid files from a prior version of the
        // daemon contain just `"12345\n"` and lack exec / boot. They MUST
        // be treated as stale so `daemon start` overwrites them.
        let path = "/tmp/sb-pid-old-\(UUID().uuidString.prefix(8)).pid"
        defer { unlink(path) }
        try "12345\n".write(toFile: path, atomically: true, encoding: .utf8)

        switch DaemonPaths.readPidFile(at: path) {
        case .stale:
            break // expected
        case .ok, .absent:
            XCTFail("old single-integer format must be treated as stale")
        }
    }

    func testReadPidFile_malformedJSON_returnsStale() throws {
        let path = "/tmp/sb-pid-bad-\(UUID().uuidString.prefix(8)).pid"
        defer { unlink(path) }
        try "not json {".write(toFile: path, atomically: true, encoding: .utf8)

        switch DaemonPaths.readPidFile(at: path) {
        case .stale:
            break // expected
        case .ok, .absent:
            XCTFail("malformed JSON must be treated as stale")
        }
    }

    func testReadPidFile_missingFields_returnsStale() throws {
        // Defensive: JSON without all three required fields → stale.
        let path = "/tmp/sb-pid-partial-\(UUID().uuidString.prefix(8)).pid"
        defer { unlink(path) }
        try #"{"pid":42}"#.write(toFile: path, atomically: true, encoding: .utf8)

        switch DaemonPaths.readPidFile(at: path) {
        case .stale:
            break
        case .ok, .absent:
            XCTFail("partial-record JSON must be treated as stale")
        }
    }

    // MARK: - 3-check liveness probe (4.2 / 4.3)

    /// 4.3 (a) — recycled pid: `kill(pid,0) == 0` succeeds because the
    /// kernel reused the pid for an unrelated process; that process's
    /// `proc_pidpath` reports a different binary AND `proc_pidinfo`
    /// reports a different start time. Result: stale.
    func testIsProcessAlive_recycledPid_returnsFalse() {
        let record = DaemonPaths.PidRecord(
            pid: 4242,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in true }, // pid is alive (something else owns it)
            exec: { _ in "/usr/sbin/cron" },
            bootTime: { _ in 1_700_999_999.0 }
        )
        XCTAssertFalse(DaemonPaths.isProcessAlive(record: record, probe: probe),
                       "recycled pid running a different binary must be stale")
    }

    /// 4.3 (b) — binary-path mismatch alone is sufficient to mark stale,
    /// even if the boot time happens to match (which would be very
    /// suspicious anyway).
    func testIsProcessAlive_binaryPathMismatch_returnsFalse() {
        let record = DaemonPaths.PidRecord(
            pid: 100,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in true },
            exec: { _ in "/tmp/cp" },
            bootTime: { _ in 1_700_000_000.0 }
        )
        XCTAssertFalse(DaemonPaths.isProcessAlive(record: record, probe: probe))
    }

    /// 4.3 (c) — happy path: pid alive, binary matches, boot time within
    /// ±2s. The 2s tolerance covers floating-point round-trip drift
    /// between `proc_pidinfo`'s integer microsecond fields and our
    /// stored TimeInterval.
    func testIsProcessAlive_happyPath_returnsTrue() {
        let record = DaemonPaths.PidRecord(
            pid: 100,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in true },
            exec: { _ in "/usr/local/bin/safari-browser" },
            bootTime: { _ in 1_700_000_000.5 } // within ±2s
        )
        XCTAssertTrue(DaemonPaths.isProcessAlive(record: record, probe: probe))
    }

    func testIsProcessAlive_killProbeFails_returnsFalse() {
        // No process at this pid at all — kill(pid,0) returns -1 with
        // ESRCH. Must short-circuit before the other checks since
        // proc_pidpath / proc_pidinfo would also fail.
        let record = DaemonPaths.PidRecord(
            pid: 99999,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in false },
            exec: { _ in nil },
            bootTime: { _ in nil }
        )
        XCTAssertFalse(DaemonPaths.isProcessAlive(record: record, probe: probe))
    }

    func testIsProcessAlive_bootTimeTooFarApart_returnsFalse() {
        // A process restart would land at a different boot time. Even if
        // exec path coincidentally matches, divergent boot time → stale.
        let record = DaemonPaths.PidRecord(
            pid: 100,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in true },
            exec: { _ in "/usr/local/bin/safari-browser" },
            bootTime: { _ in 1_700_000_010.0 } // 10s later — outside ±2s
        )
        XCTAssertFalse(DaemonPaths.isProcessAlive(record: record, probe: probe))
    }

    func testIsProcessAlive_bootTimeMissing_returnsFalse() {
        // proc_pidinfo failed (returned nil) — defensive: treat as stale
        // since we can't verify identity. Better to wrongly start a
        // second daemon than to wrongly accept a different process.
        let record = DaemonPaths.PidRecord(
            pid: 100,
            exec: "/usr/local/bin/safari-browser",
            boot: 1_700_000_000.0
        )
        let probe = DaemonPaths.PidProbe(
            killExists: { _ in true },
            exec: { _ in "/usr/local/bin/safari-browser" },
            bootTime: { _ in nil }
        )
        XCTAssertFalse(DaemonPaths.isProcessAlive(record: record, probe: probe))
    }

    // MARK: - currentPidRecord uses real syscalls

    func testCurrentPidRecord_capturesSelfPidAndExec() throws {
        // Sanity: capturing for the test process should produce a record
        // whose pid matches `getpid()` and whose exec is non-empty.
        guard let record = DaemonPaths.currentPidRecord() else {
            XCTFail("currentPidRecord must succeed for self")
            return
        }
        XCTAssertEqual(record.pid, getpid())
        XCTAssertFalse(record.exec.isEmpty, "exec path must be populated")
        XCTAssertGreaterThan(record.boot, 0, "boot time must be positive")
    }

    func testIsProcessAlive_realSelfProbe_returnsTrue() throws {
        // End-to-end: capture self, then probe self with the production
        // probe. Must report alive.
        guard let record = DaemonPaths.currentPidRecord() else {
            throw XCTSkip("cannot capture self pid record")
        }
        XCTAssertTrue(DaemonPaths.isProcessAlive(record: record, probe: .real))
    }
}
