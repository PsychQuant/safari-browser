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

    // MARK: - The dialog may change between reading it and pressing

    /// The hazard this guards is #89's, arriving through the back door. The
    /// command reads the dialog once to show its buttons, then presses. If the
    /// press resolved a *position* against a freshly-found dialog, a dialog that
    /// swapped in between — with at least as many buttons — would get one
    /// pressed. The user would have confirmed something they never saw, which is
    /// the exact thing #89 refused to build.
    ///
    /// So the press re-checks that the dialog is still the one that was read.
    private let read = SafariBridge.BlockingDialog(
        message: "Leave site?", buttons: ["Stay", "Leave"])

    func testPressesWhenTheDialogIsUnchanged() {
        XCTAssertEqual(
            DialogDismissCommand.decidePress(title: "Leave", expected: read, current: read),
            .press(index: 1))
    }

    func testRefusesWhenTheMessageChanged() {
        let other = SafariBridge.BlockingDialog(
            message: "Delete everything?", buttons: ["Stay", "Leave"])
        XCTAssertEqual(
            DialogDismissCommand.decidePress(title: "Leave", expected: read, current: other),
            .refuseDialogChanged,
            "same button layout, different question — pressing would confirm something unread")
    }

    func testRefusesWhenTheButtonsChanged() {
        let other = SafariBridge.BlockingDialog(
            message: "Leave site?", buttons: ["Stay", "Leave", "Save"])
        XCTAssertEqual(
            DialogDismissCommand.decidePress(title: "Leave", expected: read, current: other),
            .refuseDialogChanged,
            "a dialog that gained a button is not the dialog that was read")
    }

    /// The failure has to be "nothing pressed". Any outcome that presses
    /// *something* on an unrecognised dialog defeats the whole design.
    func testEveryMismatchRefusesRatherThanPressingAnything() {
        let mismatches = [
            SafariBridge.BlockingDialog(message: "x", buttons: ["Stay", "Leave"]),
            SafariBridge.BlockingDialog(message: "Leave site?", buttons: ["Leave", "Stay"]),
            SafariBridge.BlockingDialog(message: "", buttons: []),
        ]
        for m in mismatches {
            let d = DialogDismissCommand.decidePress(title: "Leave", expected: read, current: m)
            if case .press = d {
                XCTFail("pressed on a dialog that did not match what was read: \(m)")
            }
        }
    }

    /// Button order matters: the same titles in a different order is a different
    /// dialog for this purpose, because position is what ultimately gets pressed.
    func testReorderedButtonsCountAsChanged() {
        let reordered = SafariBridge.BlockingDialog(
            message: "Leave site?", buttons: ["Leave", "Stay"])
        XCTAssertEqual(
            DialogDismissCommand.decidePress(title: "Leave", expected: read, current: reordered),
            .refuseDialogChanged)
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

    /// Asserted by *parsing*, not by reading help. ArgumentParser can hide a
    /// flag from help (`.private` is documented "Never show help for this
    /// argument") while still accepting it — so a help-text oracle would let
    /// exactly the flag these tests forbid slip in behind it. Parsing sees what
    /// the command actually takes.
    private func rejectsFlag(_ flag: String) -> Bool {
        do {
            _ = try DialogDismissCommand.parse(["--button", "OK", flag])
            return false
        } catch {
            return true
        }
    }

    /// If a `--default` / `--yes` style affordance ever appears, #89's whole
    /// argument is gone: the user would be confirming something unread again,
    /// just with an extra flag.
    func testThereIsNoPressTheDefaultButtonShortcut() {
        for shortcut in ["--default", "--yes", "--accept", "--confirm", "--first"] {
            XCTAssertTrue(rejectsFlag(shortcut),
                          "\(shortcut) would re-create the unread-confirmation hazard #89 refused")
        }
        XCTAssertNoThrow(try DialogDismissCommand.parse(["--button", "OK"]),
                         "naming the button is the only way in, and it must work")
    }

    /// The path is `AXPress`, which by `docs/operation-paths.md` is not HID, so
    /// requiring the flag would be wrong and accepting it would misdescribe the
    /// mechanism. Help may still *mention* it — "this does not need --allow-hid"
    /// is exactly what belongs in help, and an assertion that forbade the string
    /// would push the docs toward saying less.
    func testDismissDoesNotAcceptAnAllowHidFlag() {
        XCTAssertTrue(rejectsFlag("--allow-hid"),
                      "AXPress sends no synthetic input; accepting the flag would misdescribe it")
    }

    /// `dialog` must not grow a sibling that presses without naming. Asserted
    /// on the configuration rather than on help, for the same reason.
    func testDialogHasOnlyListAndDismiss() {
        let names = DialogCommand.configuration.subcommands.compactMap {
            $0.configuration.commandName
        }.sorted()
        XCTAssertEqual(names, ["dismiss", "list"],
                       "a new subcommand that dismisses without naming a button would route "
                       + "around every guarantee these tests pin")
    }

    // MARK: - A title that names nothing

    /// `selectButton` trims both sides, so `--button ""` matches a button whose
    /// title is whitespace — and Foundation's whitespace set includes U+00A0 and
    /// U+200B, which render as an ordinary blank. `dialog list` shows such a
    /// button as `""`, so the user could not see what they were pressing.
    func testEmptyOrWhitespaceButtonIsRejectedAtParseTime() {
        for empty in ["", " ", "\u{00A0}", "\t"] {
            XCTAssertThrowsError(
                try DialogDismissCommand.parse(["--button", empty]),
                "--button \(empty.debugDescription) names no button and must not be accepted")
        }
    }

    /// The hole the validation closes, stated as the property it protects: a
    /// trimmed-empty title must never resolve to a button.
    func testWhitespaceTitleWouldOtherwiseHaveMatched() {
        XCTAssertEqual(
            DialogDismissCommand.selectButton(titled: "", from: [" ", "OK"]),
            .found(index: 0),
            "documents why validate() exists — without it this press would happen")
    }
}
