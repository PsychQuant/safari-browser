import XCTest
@testable import SafariBrowser

/// #126: a blocking dialog must be named on the FIRST line of stderr by every
/// targeting command, and JavaScript must refuse fast instead of waiting for
/// the 30-second osascript timeout. The AX probe itself needs a real Safari,
/// so it is injected here; these tests cover the gate that decides what to
/// do with what the probe found, and the wording the user sees.
final class BlockingDialogGateTests: XCTestCase {

    private typealias Dialog = SafariBridge.BlockingDialog

    private let sample = Dialog(
        message: "Failed to add criteria, not all criteria has been entered.",
        buttons: ["關閉"])

    /// A gate wired to a fake probe, a captured stderr, and a controllable clock.
    private func makeGate(
        probe: @escaping (BlockingDialogGate.WindowKey) -> BlockingDialogState,
        environment: [String: String] = [:],
        now: @escaping () -> Date = Date.init
    ) -> (gate: BlockingDialogGate, stderr: StderrCapture) {
        let capture = StderrCapture()
        let gate = BlockingDialogGate(
            probe: probe,
            stderr: { capture.append($0) },
            environment: environment,
            now: now)
        return (gate, capture)
    }

    // MARK: wording

    func testFirstLineNamesDialogMessageButtonsAndHint() {
        let line = BlockingDialogWarning.firstLine(windowKey: .id(2838), dialog: sample)
        XCTAssertTrue(line.hasPrefix("⚠ BLOCKING DIALOG"), "must be recognisable at a glance: \(line)")
        XCTAssertTrue(line.contains("2838"), "must say which window: \(line)")
        XCTAssertTrue(line.contains("Failed to add criteria"), "the dialog's own text identifies it: \(line)")
        XCTAssertTrue(line.contains("關閉"), "the reader needs to know what dismisses it: \(line)")
        XCTAssertTrue(line.contains("safari-browser dialog list"), "must point at the tool that handles it: \(line)")
        XCTAssertFalse(line.contains("\n"), "one line — it has to survive `tail -1`: \(line)")
    }

    func testFirstLineSaysWhenTheMessageCouldNotBeRead() {
        let line = BlockingDialogWarning.firstLine(
            windowKey: .front, dialog: Dialog(message: "", buttons: []))
        XCTAssertTrue(line.contains("no readable message"), line)
        XCTAssertTrue(line.contains("none exposed"), "buttons absent must read as absent, not as nothing: \(line)")
    }

    func testProbeUnavailableLineNamesAccessibility() {
        let line = BlockingDialogWarning.probeUnavailableLine()
        XCTAssertTrue(line.contains("Accessibility"), line)
        XCTAssertFalse(line.contains("\n"), line)
    }

    // MARK: gate decisions

    func testThrowIfBlockedThrowsTheDialogErrorWhenPresent() {
        let (gate, _) = makeGate(probe: { _ in .present(self.sample) })
        _ = gate.check(.id(2838))
        XCTAssertThrowsError(try gate.throwIfBlocked()) { error in
            guard case .javaScriptDialogBlocking(let message, let buttons) = error as? SafariBrowserError else {
                return XCTFail("expected javaScriptDialogBlocking, got \(error)")
            }
            XCTAssertEqual(message, sample.message)
            XCTAssertEqual(buttons, ["關閉"])
        }
    }

    func testThrowIfBlockedIsSilentWhenNoDialog() {
        let (gate, _) = makeGate(probe: { _ in .none })
        _ = gate.check(.front)
        XCTAssertNoThrow(try gate.throwIfBlocked())
    }

    func testThrowIfBlockedIsSilentBeforeAnyProbe() {
        let (gate, _) = makeGate(probe: { _ in .present(self.sample) })
        // Nothing resolved a target yet — the gate must not invent a dialog.
        XCTAssertNoThrow(try gate.throwIfBlocked())
        XCTAssertEqual(gate.current, .unprobed)
    }

    // MARK: stderr contract

    func testWarningIsWrittenOnceAndFirst() {
        let (gate, stderr) = makeGate(probe: { _ in .present(self.sample) })
        _ = gate.check(.id(2838))
        _ = gate.check(.id(2838))
        _ = gate.check(.front)
        XCTAssertEqual(stderr.lines.count, 1, "one warning per process, not one per command step: \(stderr.lines)")
        XCTAssertTrue(stderr.lines[0].hasPrefix("⚠ BLOCKING DIALOG"), stderr.lines[0])
    }

    func testNoWarningWhenNoDialog() {
        let (gate, stderr) = makeGate(probe: { _ in .none })
        _ = gate.check(.front)
        XCTAssertTrue(stderr.lines.isEmpty, "\(stderr.lines)")
    }

    func testAccessibilityDeniedIsReportedNotSilent() {
        let (gate, stderr) = makeGate(probe: { _ in .accessibilityDenied })
        XCTAssertEqual(gate.check(.front), .accessibilityDenied)
        XCTAssertEqual(stderr.lines.count, 1)
        XCTAssertTrue(stderr.lines[0].contains("Accessibility"), stderr.lines[0])
        XCTAssertNoThrow(try gate.throwIfBlocked(), "unknown is not 'blocked' — read-only work must proceed")
    }

    // MARK: opt-out and caching

    func testEnvironmentVariableDisablesTheProbe() {
        let calls = Counter()
        let (gate, stderr) = makeGate(
            probe: { _ in calls.increment(); return .present(self.sample) },
            environment: ["SAFARI_BROWSER_NO_DIALOG_PROBE": "1"])
        XCTAssertEqual(gate.check(.front), .unprobed)
        XCTAssertEqual(calls.value, 0, "opt-out must not pay the AX round-trip")
        XCTAssertTrue(stderr.lines.isEmpty)
        XCTAssertNoThrow(try gate.throwIfBlocked())
    }

    func testProbeResultIsReusedWithinTwoSeconds() {
        let calls = Counter()
        var clock = Date(timeIntervalSince1970: 1_000)
        let (gate, _) = makeGate(
            probe: { _ in calls.increment(); return .none },
            now: { clock })
        _ = gate.check(.id(7))
        _ = gate.check(.id(7))
        XCTAssertEqual(calls.value, 1, "a daemon / exec script must not re-probe on every step")
        clock = clock.addingTimeInterval(2.5)
        _ = gate.check(.id(7))
        XCTAssertEqual(calls.value, 2, "but a long-lived process must not trust a stale answer")
    }

    func testDifferentWindowsAreProbedSeparately() {
        let calls = Counter()
        let (gate, _) = makeGate(probe: { _ in calls.increment(); return .none })
        _ = gate.check(.id(7))
        _ = gate.check(.id(8))
        XCTAssertEqual(calls.value, 2)
    }

    // MARK: target → window key

    func testWindowKeyFollowsTheResolvedTarget() {
        XCTAssertEqual(SafariBridge.windowKey(for: .frontWindow), .front)
        XCTAssertEqual(SafariBridge.windowKey(for: .windowIndex(3)), .index(3))
        XCTAssertEqual(SafariBridge.windowKey(for: .windowTab(window: 2, tabInWindow: 5)), .index(2))
        XCTAssertEqual(
            SafariBridge.windowKey(for: .resolvedTab(windowID: 2838, tabInWindow: 1, rematch: nil, profile: nil)),
            .id(2838))
    }

    func testWindowKeyIsNilForTargetsThatStillNeedEnumeration() {
        // A `.urlMatch` has not been resolved to a window yet; probing it would
        // mean guessing. The resolver supplies the key after enumeration.
        XCTAssertNil(SafariBridge.windowKey(for: .documentIndex(4)))
    }
}

// MARK: - test doubles

private final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
