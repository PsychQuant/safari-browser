import XCTest
@testable import SafariBrowser

/// #103 — `dialog list` / `dialog dismiss`.
///
/// #89 made blocking dialogs *detectable* and deliberately refused to close
/// them: clicking an unread dialog can confirm an action the user never saw.
/// That reasoning holds for anything automatic, but it left no path at all for
/// "I can see it, I know what it says, close it" — and the dialog may be on a
/// Space the user cannot reach.
///
/// So the command exists, and the discipline that made #89 refuse is preserved
/// in its shape rather than abandoned: the button must be named, there is no
/// press-the-default shortcut, and the dialog's own text is printed before
/// anything is pressed. These tests pin that shape, since it is the part that
/// would quietly erode.
final class DialogCommandTests: XCTestCase {

    // MARK: - Naming a button

    func testExactUniqueTitleSelectsThatButton() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "取消", from: ["好", "取消"]),
            .found(index: 1))
    }

    func testUnknownTitleReportsWhatIsActuallyThere() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "Cancel", from: ["好", "取消"]),
            .notFound(available: ["好", "取消"]),
            "a miss must name the real buttons — dialogs are localized and guessing wastes a round trip")
    }

    /// Two buttons with the same title is rare but real, and pressing "one of
    /// them" is exactly the un-asked-for action this command refuses to take.
    func testDuplicateTitlesRefuseRatherThanPickOne() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "OK", from: ["OK", "Cancel", "OK"]),
            .ambiguous(title: "OK", count: 2))
    }

    func testMatchingIsExactNotFuzzy() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "OK", from: ["OK all", "Not OK"]),
            .notFound(available: ["OK all", "Not OK"]),
            "substring matching would let \"OK\" press \"OK all\" — a different action")
    }

    func testEmptyDialogHasNothingToPress() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "OK", from: []),
            .notFound(available: []))
    }

    /// Whitespace differences are a real hazard: AX titles sometimes carry
    /// padding, and a user copying a title out of `dialog list` should not fail
    /// on an invisible character.
    func testTitlesAreComparedAfterTrimmingWhitespace() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: " 取消 ", from: ["好", "取消"]),
            .found(index: 1))
    }

    // MARK: - Reporting

    func testListDescribesMessageAndButtons() {
        let out = DialogListCommand.describe(
            SafariBridge.BlockingDialog(message: "Leave site?", buttons: ["Stay", "Leave"]))
        XCTAssertTrue(out.contains("Leave site?"), "the text is the point — got: \(out)")
        XCTAssertTrue(out.contains("Stay"))
        XCTAssertTrue(out.contains("Leave"))
    }

    /// A dialog with no readable text still blocks, and saying nothing about it
    /// would read as "no dialog".
    func testListSaysSoWhenTheDialogHasNoText() {
        let out = DialogListCommand.describe(
            SafariBridge.BlockingDialog(message: "", buttons: ["OK"]))
        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(out.contains("OK"), "buttons must still be listed")
    }

    func testDismissPrintsTheDialogTextBeforePressing() {
        let preamble = DialogDismissCommand.preamble(
            for: SafariBridge.BlockingDialog(message: "Delete everything?", buttons: ["Cancel", "Delete"]),
            pressing: "Delete")
        XCTAssertTrue(preamble.contains("Delete everything?"),
                      "the log must record what was dismissed, not just that something was")
        XCTAssertTrue(preamble.contains("Delete"), "…and which button was pressed")
    }

    // MARK: - The discipline itself

    /// The flags a command *accepts*, which is USAGE plus OPTIONS. Deliberately
    /// excludes the overview prose: explaining why a flag is absent is good
    /// documentation, and an assertion that punished it would push the docs
    /// toward saying less.
    private func acceptedFlagsSection() -> String {
        let help = DialogDismissCommand.helpMessage()
        guard let usage = help.range(of: "USAGE:") else { return help }
        return String(help[usage.lowerBound...])
    }

    /// If a `--default` / `--yes` style affordance ever appears, #89's whole
    /// argument is gone: the user would be confirming something unread again,
    /// just with an extra flag.
    func testThereIsNoPressTheDefaultButtonShortcut() {
        let flags = acceptedFlagsSection()
        for shortcut in ["--default", "--yes", "--accept", "--confirm", "--first"] {
            XCTAssertFalse(flags.contains(shortcut),
                           "\(shortcut) would re-create the unread-confirmation hazard #89 refused")
        }
        XCTAssertTrue(flags.contains("--button"), "naming the button is the only way in")
    }

    /// The path is `AXPress`, which by `docs/operation-paths.md` is not HID, so
    /// requiring the flag would be wrong and offering it would misdescribe the
    /// mechanism. The overview may still *mention* it — saying "this does not
    /// need --allow-hid" is exactly the kind of thing that belongs in help.
    func testDismissDoesNotAcceptAnAllowHidFlag() {
        XCTAssertFalse(acceptedFlagsSection().contains("--allow-hid"),
                       "AXPress sends no synthetic input; accepting the flag would misdescribe it")
    }
}
