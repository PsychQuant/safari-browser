import XCTest
@testable import SafariBrowser

/// #89: how a blocking JavaScript dialog is reported.
///
/// The dialog itself cannot be created from a test — it needs a real page and
/// a real click — so these cover the part that made the incident expensive:
/// the wording. Three commands failed three contradictory ways and none named
/// a dialog, which is how forty minutes went to session timeouts, Spaces, and
/// AppleScript permissions before anyone looked for an alert.
final class BlockingDialogErrorTests: XCTestCase {

    private func message(_ error: SafariBrowserError) -> String {
        error.errorDescription ?? ""
    }

    func testNamesTheDialogAndQuotesItsText() {
        let text = message(.javaScriptDialogBlocking(
            message: "資料修改完成", buttons: ["確定"]))
        XCTAssertTrue(text.contains("dialog"), "the cause must be named outright: \(text)")
        XCTAssertTrue(text.contains("資料修改完成"), "the dialog's own text identifies it on screen: \(text)")
        XCTAssertTrue(text.contains("確定"), "the reader needs to know what dismisses it: \(text)")
    }

    func testExplainsWhyTheSymptomsLookedUnrelated() {
        // The symptoms contradict each other, so the message has to connect
        // them — otherwise the reader trusts the symptom over the diagnosis.
        let text = message(.javaScriptDialogBlocking(message: "x", buttons: ["OK"]))
        XCTAssertTrue(text.contains("timeout"), text)
        XCTAssertTrue(text.contains("empty page"), text)
        XCTAssertTrue(text.contains("System Events"), text)
    }

    func testPointsAtOtherSpaces() {
        // The window holding the dialog is frequently on another Space, which
        // is why "look at the screen" was not enough during the incident.
        let text = message(.javaScriptDialogBlocking(message: "x", buttons: []))
        XCTAssertTrue(text.contains("Space"), text)
    }

    func testSaysItWillNotDismissTheDialog() {
        // Auto-dismissing would confirm an action the user never read. The
        // message states the refusal so nobody waits for it to clear itself.
        let text = message(.javaScriptDialogBlocking(message: "Delete all?", buttons: ["OK", "Cancel"]))
        XCTAssertTrue(text.contains("will not dismiss"), text)
    }

    func testSurvivesADialogWithNothingReadable() {
        // A dialog with no readable text still blocks; reporting nothing at all
        // would be worse than reporting an unnamed one.
        let text = message(.javaScriptDialogBlocking(message: "", buttons: []))
        XCTAssertTrue(text.contains("no readable message"), text)
        XCTAssertTrue(text.contains("buttons could not be read"), text)
        XCTAssertTrue(text.contains("dialog"), text)
    }
}
