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
/// What is pinned now: the ordered effects of the native path (so "warned before
/// interfering" is a property of a value, not of prose), the warning's content
/// against what the spec requires it to say, and the complete routing truth
/// table.
///
/// **What is still not pinned, stated so nobody reads more safety into this than
/// it has**: that the interpreter in `uploadViaNativeDialog` actually writes the
/// `.warnOnStderr` payload to stderr rather than stdout, and actually executes
/// the effects in the order given. That is a `switch` with one case per effect
/// and no branching, so the surface is small — but it is untested, and closing
/// it needs an injectable sink and script runner.
final class InterferenceWarningTests: XCTestCase {

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

    // MARK: - Routing: the complete truth table

    /// All eight combinations, because the earlier version tested four and left
    /// the flag-plus-grant cases open — an implementation that inverted on
    /// `native && granted` would have passed.
    func testRoutingTruthTableIsComplete() {
        let cases: [(native: Bool, allowHid: Bool, granted: Bool, native_: Bool, why: String)] = [
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
                UploadCommand.wantsNativePath(
                    native: c.native, allowHid: c.allowHid, accessibilityGranted: c.granted),
                c.native_,
                "native=\(c.native) allowHid=\(c.allowHid) granted=\(c.granted): \(c.why)")
        }
    }

    /// The exemption is only defensible because a caller without the grant still
    /// has a path (spec condition 2). If this row ever flips to `true`, the
    /// no-grant caller is being pushed onto the interfering path by default and
    /// the spec has to be revisited — not just the code.
    func testWithoutGrantOrFlagsTheRouteIsNonInterfering() {
        XCTAssertFalse(
            UploadCommand.wantsNativePath(native: false, allowHid: false, accessibilityGranted: false))
    }
}
