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
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
        XCTAssertFalse(line.contains("\n"), "one line — it has to survive `head -1`: \(line)")
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
        XCTAssertThrowsError(try gate.throwIfBlocked(.id(2838))) { error in
            guard case .javaScriptDialogBlocking(let message, let buttons) = error as? SafariBrowserError else {
                return XCTFail("expected javaScriptDialogBlocking, got \(error)")
            }
            XCTAssertEqual(message, sample.message)
            XCTAssertEqual(buttons, ["關閉"])
        }
    }

    func testThrowIfBlockedIsSilentWhenNoDialog() {
        let (gate, _) = makeGate(probe: { _ in .clear })
        _ = gate.check(.front)
        XCTAssertNoThrow(try gate.throwIfBlocked(.front))
    }

    func testThrowIfBlockedIsSilentBeforeAnyProbe() {
        let (gate, _) = makeGate(probe: { _ in .present(self.sample) })
        // Nothing resolved a target yet — the gate must not invent a dialog.
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(2838)))
        XCTAssertEqual(gate.state(for: .id(2838)), .unprobed)
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
        let (gate, stderr) = makeGate(probe: { _ in .clear })
        _ = gate.check(.front)
        XCTAssertTrue(stderr.lines.isEmpty, "\(stderr.lines)")
    }

    func testAccessibilityDeniedIsReportedNotSilent() {
        let (gate, stderr) = makeGate(probe: { _ in .accessibilityDenied })
        XCTAssertEqual(gate.check(.front), .accessibilityDenied)
        XCTAssertEqual(stderr.lines.count, 1)
        XCTAssertTrue(stderr.lines[0].contains("Accessibility"), stderr.lines[0])
        XCTAssertNoThrow(try gate.throwIfBlocked(.front), "unknown is not 'blocked' — read-only work must proceed")
    }

    func testUnmappableWindowIsReportedNotSilent() {
        // The probe ran but could not find an AX window for the target: nobody
        // looked at that window. Saying nothing would read as "no dialog".
        let (gate, stderr) = makeGate(probe: { _ in .unprobed })
        XCTAssertEqual(gate.check(.id(999)), .unprobed)
        XCTAssertEqual(stderr.lines.count, 1, "\(stderr.lines)")
        XCTAssertTrue(stderr.lines[0].contains("999"), "must name the window it could not map: \(stderr.lines)")
        XCTAssertTrue(stderr.lines[0].contains("dialog list"), stderr.lines[0])
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(999)), "unknown is not 'blocked'")
    }

    // MARK: round-2 verify findings (#126 PR #132)

    func testFirstLineFoldsAMultilineMessageOntoOneLine() {
        // B2: `alert("a\nb")` is ordinary; the line must still survive `head -1`.
        let dialog = Dialog(message: "line one\nline two\r\nline three", buttons: ["OK\nall", "Cancel"])
        let line = BlockingDialogWarning.firstLine(windowKey: .front, dialog: dialog)
        XCTAssertFalse(line.contains("\n") || line.contains("\r"), "must be one line: \(line)")
        XCTAssertTrue(line.contains("line one line two line three"), line)
        XCTAssertTrue(line.contains("\"OK all\""), line)
    }

    func testARealDialogStillWarnsAfterAnUnmappableWindow() {
        // I1: the unavailable/unmappable notice must not silence a later real dialog.
        let (gate, stderr) = makeGate(probe: { key in key == .id(1) ? .unprobed : .present(self.sample) })
        _ = gate.check(.id(1))
        _ = gate.check(.id(2))
        XCTAssertEqual(stderr.lines.count, 2, "\(stderr.lines)")
        XCTAssertTrue(stderr.lines.last?.hasPrefix("⚠ BLOCKING DIALOG") == true, "\(stderr.lines)")
    }

    func testARealDialogStillWarnsAfterAccessibilityDenied() {
        let (gate, stderr) = makeGate(probe: { key in key == .id(1) ? .accessibilityDenied : .present(self.sample) })
        _ = gate.check(.id(1))
        _ = gate.check(.id(2))
        XCTAssertEqual(stderr.lines.count, 2, "\(stderr.lines)")
        XCTAssertTrue(stderr.lines.last?.hasPrefix("⚠ BLOCKING DIALOG") == true, "\(stderr.lines)")
    }

    func testOptOutRequiresTheValueOne() {
        // I3: `=0` in a batch script must not silently switch the probe off.
        let calls = Counter()
        let (gate, stderr) = makeGate(
            probe: { _ in calls.increment(); return .present(self.sample) },
            environment: ["SAFARI_BROWSER_NO_DIALOG_PROBE": "0"])
        XCTAssertEqual(gate.check(.front), .present(sample))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(stderr.lines.count, 1)
    }

    // MARK: round-3 — the window-list read must keep "could not read" apart from "empty"


    func testEnvironmentVariableDisablesTheProbe() {
        let calls = Counter()
        let (gate, stderr) = makeGate(
            probe: { _ in calls.increment(); return .present(self.sample) },
            environment: ["SAFARI_BROWSER_NO_DIALOG_PROBE": "1"])
        XCTAssertEqual(gate.check(.front), .unprobed)
        XCTAssertEqual(calls.value, 0, "opt-out must not pay the AX round-trip")
        XCTAssertTrue(stderr.lines.isEmpty)
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(2838)))
    }

    func testProbeResultIsReusedWithinTwoSeconds() {
        let calls = Counter()
        var clock = TimeInterval(1_000)
        let (gate, _) = makeGate(
            probe: { _ in calls.increment(); return .clear },
            now: { clock })
        _ = gate.check(.id(7))
        _ = gate.check(.id(7))
        XCTAssertEqual(calls.value, 1, "a daemon / exec script must not re-probe on every step")
        clock += 2.5
        _ = gate.check(.id(7))
        XCTAssertEqual(calls.value, 2, "but a long-lived process must not trust a stale answer")
    }

    func testDifferentWindowsAreProbedSeparately() {
        let calls = Counter()
        let (gate, _) = makeGate(probe: { _ in calls.increment(); return .clear })
        _ = gate.check(.id(7))
        _ = gate.check(.id(8))
        XCTAssertEqual(calls.value, 2)
    }

    func testExpiredPresentVerdictCannotKeepBlocking() {
        var clock = TimeInterval(1000)
        let (gate, _) = makeGate(probe: { _ in .present(self.sample) }, now: { clock })
        gate.check(.id(7))
        clock += 2
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(7)), "an expired answer is not evidence of a current dialog")
    }

    func testSlowProbeDoesNotSerializeOtherWindowsBehindStateLock() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstFinished = expectation(description: "first probe finishes")
        let secondFinished = expectation(description: "second window can finish independently")
        let (gate, _) = makeGate(probe: { key in
            if key == .id(1) {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return .clear
        })
        DispatchQueue.global().async { gate.check(.id(1)); firstFinished.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { gate.check(.id(2)); secondFinished.fulfill() }
        await fulfillment(of: [secondFinished], timeout: 0.2)
        release.signal()
        await fulfillment(of: [firstFinished], timeout: 1)
    }

    func testVerdictsAreQueriedOnlyForTheRequestedWindow() {
        let (gate, _) = makeGate(probe: { key in key == .id(1) ? .present(self.sample) : .clear })
        gate.check(.id(1))
        XCTAssertEqual(gate.state(for: .id(2)), .unprobed)
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(2)))
        gate.check(.id(2))
        XCTAssertEqual(gate.state(for: .id(1)), .present(sample))
        XCTAssertEqual(gate.state(for: .id(2)), .clear)
        XCTAssertThrowsError(try gate.throwIfBlocked(.id(1)))
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(2)))
    }

    func testStateQueryExpiresAtTTLWithoutReprobing() {
        let calls = Counter()
        var clock: TimeInterval = 10
        let (gate, _) = makeGate(probe: { _ in calls.increment(); return .present(self.sample) }, now: { clock })
        gate.check(.id(1))
        clock = 11.999
        XCTAssertEqual(gate.state(for: .id(1)), .present(sample))
        clock = 12
        XCTAssertEqual(gate.state(for: .id(1)), .unprobed)
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(1)))
        XCTAssertEqual(calls.value, 1, "state queries must not perform hidden AX work")
        gate.check(.id(1))
        XCTAssertEqual(calls.value, 2)
    }

    func testForcedRefreshReplacesFreshVerdict() {
        var blocked = true
        let (gate, _) = makeGate(probe: { _ in blocked ? .present(self.sample) : .clear })
        gate.check(.id(1))
        blocked = false
        XCTAssertEqual(gate.check(.id(1)), .present(sample))
        XCTAssertEqual(gate.check(.id(1), forceRefresh: true), .clear)
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(1)))
    }

    func testLateOlderProbeDoesNotOverwriteNewerVerdict() async {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "older probe returns")
        let calls = Counter()
        let sample = self.sample
        let (gate, _) = makeGate(probe: { _ in
            calls.increment()
            if calls.value == 1 {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
                return .present(sample)
            }
            return .clear
        })
        DispatchQueue.global().async { gate.check(.id(1)); firstDone.fulfill() }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(gate.check(.id(1), forceRefresh: true), .clear)
        releaseFirst.signal()
        await fulfillment(of: [firstDone], timeout: 1)
        XCTAssertEqual(gate.state(for: .id(1)), .clear)
        XCTAssertNoThrow(try gate.throwIfBlocked(.id(1)))
    }

    func testResetDiscardsAnInflightProbeResult() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "probe finishes after reset")
        let sample = self.sample
        let (gate, capture) = makeGate(probe: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return .present(sample)
        })
        DispatchQueue.global().async { gate.check(.id(1)); finished.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        gate.reset()
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(gate.state(for: .id(1)), .unprobed)
        XCTAssertTrue(capture.lines.isEmpty)
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
        XCTAssertNil(SafariBridge.windowKey(for: .urlMatch(.contains("fixture"))))
    }
    func testCommandStopsProbingAfterItsTotalBudgetIsSpent() {
        var clock: TimeInterval = 100
        var calls = 0
        let (gate, _) = makeGate(probe: { _ in
            calls += 1
            clock += 0.1
            return .clear
        }, now: { clock })
        XCTAssertEqual(gate.check(.id(1)), .clear)
        XCTAssertEqual(gate.check(.id(2)), .clear)
        XCTAssertEqual(gate.check(.id(3)), .unprobed)
        XCTAssertEqual(calls, 2)
    }

    func testNextLogicalCommandRefreshesBudgetWithoutRepeatingRequestWarning() {
        var clock: TimeInterval = 100
        var calls = 0
        let (gate, stderr) = makeGate(probe: { _ in
            calls += 1
            clock += 0.1
            return .present(self.sample)
        }, now: { clock })
        gate.check(.id(1))
        gate.check(.id(2))
        XCTAssertEqual(gate.check(.id(3)), .unprobed)
        gate.beginCommand()
        guard case .present = gate.check(.id(3)) else { return XCTFail("new command needs a fresh probe") }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(stderr.lines.filter { $0.contains("BLOCKING DIALOG") }.count, 1)
    }

    func testEveryUnicodeLineSeparatorAndAllNewlineMessage() {
        for separator in ["\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(BlockingDialogWarning.oneLine("a" + separator + "b"), "a b")
            XCTAssertEqual(BlockingDialogWarning.messageText(Dialog(message: separator, buttons: [])), "(no readable message)")
        }
    }

    func testDebugRequiresExactlyOne() {
        for value in ["0", "", "true", "1"] {
            let (gate, stderr) = makeGate(probe: { _ in .clear },
                environment: [BlockingDialogGate.debugVariable: value])
            gate.check(.id(42))
            XCTAssertEqual(stderr.lines.contains(where: { $0.hasPrefix("dialog probe:") }), value == "1")
        }
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
