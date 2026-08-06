import XCTest
@testable import SafariBrowser

/// #104 — the `non-interference` spec lets a macOS TCC grant stand in for a
/// per-invocation opt-in flag, but only under three conditions. Condition 2 is
/// that the command still warns on stderr before it interferes:
///
///   > The command emits the `Interference warning on stderr` required below,
///   > on the interfering path, before the interference begins.
///
/// That condition is what keeps the exception honest — it is the whole reason a
/// grant is allowed to substitute for a flag. `upload` is the only command that
/// currently exercises the exception, and its warning had no test, so nothing
/// stopped someone from deleting or softening it and quietly turning the
/// exception into silent interference.
///
/// The emission itself needs a real Safari and a real file dialog, so these
/// tests pin the *wording* — which is what actually regresses — against the two
/// things the spec's `Interference warning on stderr` requirement demands it say.
final class InterferenceWarningTests: XCTestCase {

    /// Requirement item 1: "What type of interference will occur (e.g.,
    /// 'keyboard control', 'file dialog')".
    func testWarningNamesTheInterferenceType() {
        let w = UploadCommand.keyboardControlWarning
        XCTAssertTrue(
            w.localizedCaseInsensitiveContains("keyboard"),
            "warning must name keyboard control as the interference type; got: \(w)")
        XCTAssertTrue(
            w.localizedCaseInsensitiveContains("file dialog"),
            "warning must name the file dialog as the interference type; got: \(w)")
    }

    /// Requirement item 2: "That the user's input devices will be temporarily
    /// unavailable". Wording is free, but it has to actually tell the user not
    /// to type — a warning that only says "controlling keyboard" leaves them
    /// guessing whether their own typing is safe.
    func testWarningTellsTheUserNotToType() {
        let w = UploadCommand.keyboardControlWarning
        XCTAssertTrue(
            w.localizedCaseInsensitiveContains("do not type"),
            "warning must tell the user their input is unavailable; got: \(w)")
    }

    /// The spec requires the warning on stderr specifically, "to avoid polluting
    /// command output". A trailing newline is part of that contract — stderr
    /// lines that run together are the reason interleaved output is unreadable.
    func testWarningIsASingleCompleteLine() {
        let w = UploadCommand.keyboardControlWarning
        XCTAssertTrue(w.hasSuffix("\n"), "warning must terminate its line")
        XCTAssertEqual(
            w.filter { $0 == "\n" }.count, 1,
            "warning should be one line — multi-line stderr noise buries the signal")
    }

    /// Guards the exception's precondition rather than its consequence: the
    /// grant substitution is only defensible because a caller *without* the
    /// grant still gets a working command (condition 3). If this ever inverts —
    /// no grant meaning no upload — the exception's justification collapses and
    /// the spec has to be revisited, not just the code.
    func testFlaglessRoutingPrefersNativeOnlyWhenGranted() {
        XCTAssertTrue(
            UploadCommand.wantsNativePath(native: false, allowHid: false, accessibilityGranted: true),
            "with the grant, a flagless upload takes the native path (the #104 exception)")
        XCTAssertFalse(
            UploadCommand.wantsNativePath(native: false, allowHid: false, accessibilityGranted: false),
            "without the grant, a flagless upload must fall to the non-interfering JS path")
    }

    /// Explicit flags keep working regardless of the grant — the exception adds
    /// a way to authorize, it does not remove the existing one.
    func testExplicitFlagsStillForceNative() {
        XCTAssertTrue(
            UploadCommand.wantsNativePath(native: true, allowHid: false, accessibilityGranted: false),
            "--native forces the native path even with no grant")
        XCTAssertTrue(
            UploadCommand.wantsNativePath(native: false, allowHid: true, accessibilityGranted: false),
            "--allow-hid forces the native path even with no grant")
    }
}
