import XCTest
@testable import SafariBrowser

/// #104 — the `non-interference` spec normally requires an explicit opt-in flag
/// before any interference. `upload` has one named exemption: with the macOS
/// Accessibility grant present it may take the native path with no flag. The
/// exemption's first condition is that the user is still warned, on stderr,
/// *before* the interference begins.
///
/// An earlier version of this file asserted only on the warning's wording and
/// on a routing predicate. That was too weak to be worth much: deleting the
/// stderr write, sending it to stdout, moving it after the first keystroke, or
/// simply not calling the predicate would all have left every assertion green.
/// The Codex review of the first cut said so, and it was right.
///
/// A second review round found the first fix still too weak: it described the
/// sequence as data and tested the description, so an interpreter that ignored
/// the plan would have passed. The side effects are now injected, and these
/// tests run the real `runNativeUploadEffects` and `resolveNativeRouting` and
/// watch what they do.
///
/// **What is still not pinned** — stated in full this time, because the previous
/// version of this note was itself incomplete and a partial disclosure reads as
/// a complete one:
///
/// 1. That `uploadViaNativeDialog` binds `warn` to **stderr** rather than
///    stdout. It is one closure literal at the call site.
/// 2. That `uploadViaNativeDialog` calls `nativeUploadEffects` at all, rather
///    than hand-rolling an equivalent sequence.
/// 3. That `run()` routes through `resolveNativeRouting` rather than deciding
///    inline.
///
/// (2) and (3) are the regress inherent in testing a function rather than its
/// caller; closing them means executing `run()` itself with every dependency
/// injected, which is a larger seam than this issue warranted. What is closed is
/// the part that silently rots: the interpreter and the routing themselves.
final class InterferenceWarningTests: XCTestCase {

    /// Records what the real interpreter did, in order.
    private final class Recorder: @unchecked Sendable {
        private(set) var events: [String] = []
        func log(_ e: String) { events.append(e) }
    }

    private let selector = "input[type=file]"
    private let path = "/tmp/example.mp3"

    private func effects(window: Int? = nil) -> [UploadCommand.NativeUploadEffect] {
        UploadCommand.nativeUploadEffects(selector: selector, path: path, window: window)
    }

    // MARK: - Order: warned before anything interferes

    /// The spec's condition is "before the interference begins", and interference
    /// begins when the file chooser opens — not when the first keystroke lands.
    /// A warning emitted between the dialog and the keystrokes would satisfy a
    /// naive reading and still surprise the user with a dialog they never asked for.
    func testWarningIsTheVeryFirstEffect() {
        guard case .warnOnStderr(let text)? = effects().first else {
            return XCTFail("the first effect must be the stderr warning; got \(effects())")
        }
        XCTAssertEqual(text, UploadCommand.keyboardControlWarning,
                       "the warning emitted must be the pinned constant, not an ad-hoc string")
    }

    func testDialogOpensAfterTheWarningAndKeystrokesAfterThat() {
        let e = effects()
        guard e.count == 3 else { return XCTFail("expected warn → open dialog → run script; got \(e)") }
        guard case .warnOnStderr = e[0] else { return XCTFail("effect 0 must warn") }
        guard case .openDialogByClickingFileInput = e[1] else {
            return XCTFail("effect 1 must open the chooser — interference #1")
        }
        guard case .runCombinedScript = e[2] else {
            return XCTFail("effect 2 must run the keystroke script — interference #2")
        }
    }

    /// #15: the keystroke flow must stay a single invocation. Two would let
    /// another app steal focus in the gap.
    func testExactlyOneScriptIsRun() {
        let scripts = effects().filter { if case .runCombinedScript = $0 { return true }; return false }
        XCTAssertEqual(scripts.count, 1, "splitting the script reintroduces the #15 focus race")
    }

    func testDialogIsOpenedByClickingRatherThanByKeystroke() {
        guard case .openDialogByClickingFileInput(let sel, let js)? = effects().dropFirst().first else {
            return XCTFail("expected the chooser to be opened by a click")
        }
        XCTAssertEqual(sel, selector)
        XCTAssertTrue(js.contains("el.click()"),
                      "the chooser is opened via JS, which is non-HID — only the navigation needs keystrokes")
        XCTAssertTrue(js.contains("NOT_FOUND"), "must be able to report a missing input")
    }

    // MARK: - Content: what the spec requires the warning to say

    /// Requirement item 1: "What type of interference will occur".
    func testWarningNamesTheInterferenceType() {
        let w = UploadCommand.keyboardControlWarning
        XCTAssertTrue(w.localizedCaseInsensitiveContains("keyboard"), "got: \(w)")
        XCTAssertTrue(w.localizedCaseInsensitiveContains("file dialog"), "got: \(w)")
    }

    /// Requirement item 2: "That the user's input devices will be temporarily
    /// unavailable". A warning that only says "controlling keyboard" leaves the
    /// user guessing whether their own typing is safe.
    func testWarningTellsTheUserNotToType() {
        XCTAssertTrue(
            UploadCommand.keyboardControlWarning.localizedCaseInsensitiveContains("do not type"),
            "got: \(UploadCommand.keyboardControlWarning)")
    }

    func testWarningTerminatesItsLine() {
        // Not a spec requirement — a practical one. Unterminated stderr writes
        // run into whatever is printed next.
        XCTAssertTrue(UploadCommand.keyboardControlWarning.hasSuffix("\n"))
    }

    // MARK: - The real interpreter, not a description of it

    func testInterpreterWarnsBeforeItInterferes() async throws {
        let r = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            effects(),
            jsTarget: .frontWindow,
            warn: { _ in r.log("warn") },
            runJS: { _, _ in r.log("open-chooser"); return "OK" },
            runScript: { _ in r.log("keystrokes") })
        XCTAssertEqual(r.events, ["warn", "open-chooser", "keystrokes"],
                       "the warning must precede BOTH interfering effects, not just the keystrokes")
    }

    func testInterpreterPassesThePinnedWarningText() async throws {
        let r = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            effects(),
            jsTarget: .frontWindow,
            warn: { r.log($0) },
            runJS: { _, _ in "OK" },
            runScript: { _ in })
        XCTAssertEqual(r.events.first, UploadCommand.keyboardControlWarning)
    }

    func testInterpreterRunsExactlyOneScript() async throws {
        let r = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            effects(),
            jsTarget: .frontWindow,
            warn: { _ in },
            runJS: { _, _ in "OK" },
            runScript: { _ in r.log("script") })
        XCTAssertEqual(r.events.count, 1, "two invocations reintroduce the #15 focus race")
    }

    /// A missing file input must stop the flow — not fall through to keystrokes
    /// aimed at a dialog that never opened.
    func testInterpreterStopsWhenTheFileInputIsMissing() async throws {
        let r = Recorder()
        do {
            try await UploadCommand.runNativeUploadEffects(
                effects(),
                jsTarget: .frontWindow,
                warn: { _ in },
                runJS: { _, _ in "NOT_FOUND" },
                runScript: { _ in r.log("keystrokes") })
            XCTFail("expected elementNotFound")
        } catch {
            XCTAssertTrue(r.events.isEmpty, "no keystrokes may be sent after the chooser failed to open")
        }
    }

    // MARK: - Routing: truth table and short-circuit

    /// All eight combinations. The earlier version tested four and left the
    /// flag-plus-grant cases open, so an implementation that inverted on
    /// `native && granted` would have passed.
    func testRoutingTruthTableIsComplete() {
        let cases: [(native: Bool, allowHid: Bool, granted: Bool, wantsNative: Bool, why: String)] = [
            (false, false, false, false, "no flag, no grant → the non-interfering JS path"),
            (false, false, true,  true,  "no flag, grant present → the #104 exemption"),
            (false, true,  false, true,  "--allow-hid alone forces native"),
            (false, true,  true,  true,  "--allow-hid with a grant is still native"),
            (true,  false, false, true,  "--native alone forces native"),
            (true,  false, true,  true,  "--native with a grant is still native"),
            (true,  true,  false, true,  "both flags, no grant → native"),
            (true,  true,  true,  true,  "both flags and a grant → native"),
        ]
        for c in cases {
            XCTAssertEqual(
                UploadCommand.resolveNativeRouting(
                    native: c.native, allowHid: c.allowHid, accessibilityProbe: { c.granted }),
                c.wantsNative,
                "native=\(c.native) allowHid=\(c.allowHid) granted=\(c.granted): \(c.why)")
        }
    }

    /// An explicit flag decides on its own, so the TCC permission API must not
    /// be consulted at all. Folding the probe into an argument list once made it
    /// eager — same truth table, different number of system calls.
    func testExplicitFlagShortCircuitsThePermissionProbe() {
        for (native, allowHid) in [(true, false), (false, true), (true, true)] {
            var probes = 0
            _ = UploadCommand.resolveNativeRouting(
                native: native, allowHid: allowHid,
                accessibilityProbe: { probes += 1; return false })
            XCTAssertEqual(probes, 0,
                           "native=\(native) allowHid=\(allowHid): the flag already decided")
        }
    }

    func testProbeIsConsultedExactlyOnceWhenNoFlagIsGiven() {
        var probes = 0
        _ = UploadCommand.resolveNativeRouting(
            native: false, allowHid: false,
            accessibilityProbe: { probes += 1; return true })
        XCTAssertEqual(probes, 1, "the grant decides the flagless case, and one check is enough")
    }
}
