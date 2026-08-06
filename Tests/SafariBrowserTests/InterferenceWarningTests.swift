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
/// **The boundary of what these tests can see.** Two earlier attempts at this
/// note enumerated the gaps and were incomplete both times — and a list that
/// looks exhaustive but isn't is worse than no list, because it invites the
/// reader to stop checking. So this states the boundary instead of itemising
/// what falls outside it:
///
/// > These tests execute `nativeUploadEffects`, `runNativeUploadEffects` and
/// > `resolveNativeRouting` directly. **Nothing about how `UploadCommand.run()`
/// > and `uploadViaNativeDialog` use them is tested at all** — not whether they
/// > call these functions, not what they pass, not what they bind the closures
/// > to, not what they do with the results.
///
/// Concretely, that means the production path could still filter `.warnOnStderr`
/// out of the plan before handing it over, bind `warn` to stdout, build the plan
/// from the wrong selector, pass an eagerly-evaluated `{ granted }` instead of
/// the probe itself, or ignore the routing result — and everything here would
/// stay green. Closing that needs `run()` itself executed with every dependency
/// injected, which is a larger seam than this issue warranted.
///
/// What *is* closed is the part that rots quietly once written: these three
/// functions' own behavior, including that the interpreter reads the plan it is
/// given rather than performing a fixed sequence.
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
    /// aimed at a dialog that never opened. The error has to be the specific
    /// one, carrying the selector: "it threw something" would also be satisfied
    /// by an implementation that throws unconditionally.
    func testInterpreterStopsWithElementNotFoundWhenTheFileInputIsMissing() async throws {
        let r = Recorder()
        do {
            try await UploadCommand.runNativeUploadEffects(
                [.openDialogByClickingFileInput(selector: "#chooser", js: "js"),
                 .runCombinedScript("script")],
                jsTarget: .frontWindow,
                warn: { _ in },
                runJS: { _, _ in "NOT_FOUND" },
                runScript: { _ in r.log("keystrokes") })
            XCTFail("expected elementNotFound")
        } catch let e as SafariBrowserError {
            guard case .elementNotFound(let sel) = e else {
                return XCTFail("expected .elementNotFound, got \(e)")
            }
            XCTAssertEqual(sel, "#chooser", "the error must name the selector from the plan")
            XCTAssertTrue(r.events.isEmpty, "no keystrokes after the chooser failed to open")
        }
    }

    /// An error from a runner must propagate rather than be swallowed and the
    /// remaining effects skipped silently.
    func testInterpreterPropagatesRunnerFailures() async throws {
        struct Boom: Error {}
        do {
            try await UploadCommand.runNativeUploadEffects(
                [.runCombinedScript("s"), .warnOnStderr("unreachable")],
                jsTarget: .frontWindow,
                warn: { _ in XCTFail("must not continue past a failed script") },
                runJS: { _, _ in "OK" },
                runScript: { _ in throw Boom() })
            XCTFail("expected the runner's error to propagate")
        } catch is Boom {
            // expected
        }
    }

    // MARK: - The interpreter reads the plan, rather than performing a fixed sequence

    /// Without this, an interpreter that ignored its argument and hard-coded
    /// warn → click → script would pass every other test in this file.
    func testInterpreterForwardsThePlansOwnPayloads() async throws {
        var warned: [String] = []
        var jsCalls: [String] = []
        var scripts: [String] = []
        var targetWasWindow7 = false

        try await UploadCommand.runNativeUploadEffects(
            [.warnOnStderr("SENTINEL-WARN"),
             .openDialogByClickingFileInput(selector: "SENTINEL-SEL", js: "SENTINEL-JS"),
             .runCombinedScript("SENTINEL-SCRIPT")],
            jsTarget: .windowIndex(7),
            warn: { warned.append($0) },
            runJS: { js, target in
                jsCalls.append(js)
                if case .windowIndex(7) = target { targetWasWindow7 = true }
                return "OK"
            },
            runScript: { scripts.append($0) })

        XCTAssertEqual(warned, ["SENTINEL-WARN"], "must emit the plan's text, not a constant of its own")
        XCTAssertEqual(jsCalls, ["SENTINEL-JS"], "must run the plan's JS verbatim")
        XCTAssertEqual(scripts, ["SENTINEL-SCRIPT"], "must run the plan's script verbatim")
        XCTAssertTrue(targetWasWindow7, "must pass the caller's jsTarget through unchanged")
    }

    func testInterpreterFollowsThePlansOrderRatherThanAFixedOne() async throws {
        let r = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            [.runCombinedScript("s"), .warnOnStderr("w")],   // deliberately inverted
            jsTarget: .frontWindow,
            warn: { _ in r.log("warn") },
            runJS: { _, _ in "OK" },
            runScript: { _ in r.log("script") })
        XCTAssertEqual(r.events, ["script", "warn"],
                       "the order must come from the plan — a hard-coded sequence would give warn first")
    }

    func testInterpreterHonoursRepeatsAndDoesNothingOnAnEmptyPlan() async throws {
        let r = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            [], jsTarget: .frontWindow,
            warn: { _ in r.log("warn") }, runJS: { _, _ in "OK" }, runScript: { _ in })
        XCTAssertEqual(r.events, [], "an empty plan must do nothing")

        let r2 = Recorder()
        try await UploadCommand.runNativeUploadEffects(
            [.warnOnStderr("a"), .warnOnStderr("b")],
            jsTarget: .frontWindow,
            warn: { r2.log($0) }, runJS: { _, _ in "OK" }, runScript: { _ in })
        XCTAssertEqual(r2.events, ["a", "b"], "each effect must be interpreted, including repeats")
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
