import ApplicationServices
import ArgumentParser
import Foundation

/// #103 — inspect and dismiss a blocking Safari dialog.
///
/// #89 made these dialogs detectable and refused to close them, on the grounds
/// that clicking an unread dialog can confirm an action the user never saw.
/// That holds for anything automatic. It left no path at all for the case where
/// the user *has* read it — or cannot, because the dialog is on a Space they
/// are not looking at — and just wants it gone.
///
/// This is that path, shaped so the original objection still bites: the button
/// has to be named, there is no press-the-default shortcut, and the dialog's own
/// text is printed before anything happens. Automatic dismissal remains absent
/// and should stay absent.
struct DialogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dialog",
        abstract: "Inspect or dismiss a blocking Safari dialog (alert / confirm / file picker)",
        subcommands: [DialogListCommand.self, DialogDismissCommand.self],
        defaultSubcommand: DialogListCommand.self
    )
}

struct DialogListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show the blocking dialog's text and buttons, if one is present"
    )

    @Option(name: .customLong("window-id"), help: "Inspect only this stable Safari window ID (not a window index)")
    var windowID: Int?

    func validate() throws {
        if let windowID, windowID <= 0 {
            throw ValidationError("--window-id must be a positive stable window ID, not a window index")
        }
    }

    /// Rendered separately from the printing so the wording is testable.
    ///
    /// Message and buttons go through the same helpers as the #126 entry-point
    /// warning, so the two never describe one dialog in two vocabularies: an
    /// agent that saw the one-line warning recognises the same dialog here. A
    /// dialog with no readable text still blocks; the helper's stand-in says
    /// so rather than reading as "no dialog".
    static func describe(_ dialog: SafariBridge.BlockingDialog, windowID: Int? = nil) -> String {
        let target = windowID.map { " --window-id \($0)" } ?? ""
        let identity = windowID.map { "\n  window: Safari window id \($0)" } ?? ""
        return """
        blocking dialog present
          message: \(BlockingDialogWarning.messageText(dialog))
          buttons: \(BlockingDialogWarning.buttonsText(dialog))\(identity)

        To dismiss it, name the button:
          safari-browser dialog dismiss\(target) --button "<title>"
        """
    }

    static let noDialogMessage = "no blocking dialog found"
    static let undetectedDialogGuidance = "The inspection covers the supported native Accessibility tree only. "
        + "If a dialog is visible, stop automation and handle it manually; Safari may not expose it through this tree. "
        + "Do not repeat the page action."

    static func reportVisibilityLimit() {
        FileHandle.standardError.write(Data((undetectedDialogGuidance + "\n").utf8))
    }

    func run() async throws {
        let observation = SafariBridge.observeBlockingDialogs(windowID: windowID)
        print(try Self.output(for: observation.scanResult, windowID: windowID ?? observation.singleDialogWindowID))
        if observation.scanResult == .none { Self.reportVisibilityLimit() }
    }

    static func output(for scan: SafariBridge.DialogScan, windowID: Int? = nil) throws -> String {
        let scope = windowID.map { "Safari window id \($0)\n" } ?? ""
        switch scan {
        case .inspectionIncomplete:
            throw SafariBrowserError.dialogInspectionIncomplete
        case .sessionLocked:
            throw SafariBrowserError.guiSessionLocked
        case .sessionUnavailable:
            throw SafariBrowserError.guiSessionUnavailable
        case .accessibilityDenied:
            throw SafariBrowserError.accessibilityRequired(flag: "dialog list")
        case .none:
            return scope + DialogListCommand.noDialogMessage
        case .one(let dialog):
            return DialogListCommand.describe(dialog, windowID: windowID)
        case .many(let messages):
            // Fail-closed rather than showing one of several: the next step is
            // `dismiss`, and a listing that silently picked one would send the
            // user to press a button on a dialog they were not shown.
            throw SafariBrowserError.ambiguousBlockingDialog(messages: messages)
        }
    }
}

struct DialogDismissCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Press a named button on the blocking dialog",
        discussion: """
            The button must be named exactly, as shown by `dialog list`. There is
            deliberately no way to press "the default button" — that is the
            unread-confirmation hazard #89 refused to build, and a flag would not
            make it safer.

            Uses the Accessibility press action, which sends no synthetic key or
            mouse events, so it neither moves the cursor nor needs --allow-hid.
            It does change state, which is why you have to ask for it.
            """
    )

    @Option(name: .long, help: "Exact title of the button to press, as shown by `dialog list`")
    var button: String

    @Option(name: .customLong("window-id"), help: "Inspect and dismiss only within this stable Safari window ID (not a window index)")
    var windowID: Int?

    var inspectionWindowID: Int? { windowID ?? expectWindowID }

    @Option(name: .customLong("expect-window-id"), help: "Expected stable Safari window ID; requires --expect-message")
    var expectWindowID: Int?

    @Option(name: .long, help: "Expected raw dialog message; requires --expect-window-id")
    var expectMessage: String?

    static let expectationMismatch = "Dialog does not match the supplied expectation; no button was pressed."

    static func validateExpectedMessage(_ expected: String?, actual: SafariBridge.BlockingDialog) throws {
        guard let expected else { return }
        guard actual.message == expected else { throw ValidationError(expectationMismatch) }
    }

    /// Which button a title names, or why it names none.
    ///
    /// Exact match after trimming — deliberately not a substring or fuzzy match.
    /// "OK" must not press "OK all": that is a different action, and picking the
    /// nearest one is the class of guess this command exists to avoid.
    enum ButtonSelection: Equatable {
        case found(index: Int)
        case notFound(available: [String])
        case ambiguous(title: String, count: Int)
    }

    static func selectButton(titled title: String, from buttons: [String]) -> ButtonSelection {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = buttons.enumerated().filter {
            $0.element.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        switch matches.count {
        case 1: return .found(index: matches[0].offset)
        case 0: return .notFound(available: buttons)
        default: return .ambiguous(title: wanted, count: matches.count)
        }
    }

    /// Whether to press, decided against the dialog *as it is at press time*.
    ///
    /// The command reads the dialog once to show its buttons and to resolve the
    /// title the user named, then presses. Those are two separate Accessibility
    /// lookups, and between them the page can dismiss the dialog and put up
    /// another one. Deciding by *position* would then press a button on a dialog
    /// the user never saw — #89's hazard, arriving through the back door, and
    /// caught only when the replacement happened to have fewer buttons.
    ///
    /// So the decision is made against the current dialog and refuses unless it
    /// is still the one that was read. The fingerprint is message plus button
    /// titles in order: not a true identity, but a dialog matching both is the
    /// one the user read for any purpose that matters here. Every mismatch
    /// presses nothing, which is the only acceptable direction for this to fail.
    enum PressDecision: Equatable {
        case press(index: Int)
        case refuseDialogChanged
        case refuseButtonGone(available: [String])
        case refuseAmbiguous(title: String, count: Int)
    }

    static func decidePress(
        title: String,
        expected: SafariBridge.BlockingDialog,
        current: SafariBridge.BlockingDialog
    ) -> PressDecision {
        guard current == expected else { return .refuseDialogChanged }
        switch selectButton(titled: title, from: current.buttons) {
        case .found(let index): return .press(index: index)
        case .notFound(let available): return .refuseButtonGone(available: available)
        case .ambiguous(let t, let count): return .refuseAmbiguous(title: t, count: count)
        }
    }

    /// Printed before the press, so the log records *what* was dismissed rather
    /// than only that something was. Reconstructing that afterwards is
    /// impossible — the dialog is gone.
    static func preamble(for dialog: SafariBridge.BlockingDialog, pressing button: String) -> String {
        """
            dismissing dialog
              message: \(BlockingDialogWarning.messageText(dialog))
              pressing: \(TerminalText.quotedDialogField(button))
            """
    }

    /// A title that trims to nothing names no button — but `selectButton`
    /// trims both sides, so `--button ""` would match a button whose title is
    /// whitespace, and Foundation's whitespace set includes characters like
    /// U+00A0 and U+200B that render as an ordinary-looking blank. `dialog list`
    /// shows such a button as `""`, so the user cannot even see what they would
    /// be pressing. Rejected at parse time rather than handled later.
    func validate() throws {
        if let windowID, windowID <= 0 {
            throw ValidationError("--window-id must be a positive stable window ID, not a window index")
        }
        if let windowID, let expectWindowID, windowID != expectWindowID {
            throw ValidationError("--window-id and --expect-window-id must identify the same window")
        }
        guard (expectWindowID == nil) == (expectMessage == nil) else {
            throw ValidationError("--expect-window-id and --expect-message must be supplied together")
        }
        if let expectWindowID, expectWindowID <= 0 {
            throw ValidationError("--expect-window-id must be a positive stable window ID, not a window index")
        }
        if button.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError(
                "--button needs the button's title. An empty or whitespace-only value names "
                + "nothing, and this command never presses a button you did not name.")
        }
    }

    func run() async throws {
        try execute(
            inspect: { SafariBridge.observeBlockingDialogs(windowID: $0) },
            press: { expectedID, scope, decide in
                SafariBridge.pressDialogButton(expectedWindowID: expectedID, windowID: scope, deciding: decide)
            })
    }

    /// The same scope is used for observation, synchronous re-read/press and
    /// post-action reporting. Dependencies keep AX operations at the boundary.
    func execute(
        inspect: (Int?) -> WindowDialogObservation,
        press: (Int, Int?, (SafariBridge.BlockingDialog) -> Int?) -> SafariBridge.DialogPressOutcome
    ) throws {
        let observation = inspect(inspectionWindowID)
        let dialog: SafariBridge.BlockingDialog
        switch observation.scanResult {
        case .inspectionIncomplete:
            throw SafariBrowserError.dialogInspectionIncomplete
        case .sessionLocked:
            throw SafariBrowserError.guiSessionLocked
        case .sessionUnavailable:
            throw SafariBrowserError.guiSessionUnavailable
        case .accessibilityDenied:
            throw SafariBrowserError.accessibilityRequired(flag: "dialog dismiss")
        case .none:
            throw SafariBrowserError.noBlockingDialog
        case .many(let messages):
            throw SafariBrowserError.ambiguousBlockingDialog(messages: messages)
        case .one(let d):
            dialog = d
        }

        guard let observedWindowID = observation.singleDialogWindowID, observedWindowID > 0 else {
            throw SafariBrowserError.dialogInspectionIncomplete
        }
        if let inspectionWindowID, observedWindowID != inspectionWindowID {
            throw ValidationError(Self.expectationMismatch)
        }

        try Self.validateExpectedMessage(expectMessage, actual: dialog)
        switch DialogDismissCommand.selectButton(titled: button, from: dialog.buttons) {
        case .notFound(let available):
            throw SafariBrowserError.dialogButtonNotFound(titled: button, available: available)
        case .ambiguous(let title, let count):
            throw SafariBrowserError.dialogButtonAmbiguous(titled: title, count: count)
        case .found:
            print("Safari window id \(observedWindowID)")
            print(DialogDismissCommand.preamble(for: dialog, pressing: button))

            // The press re-reads the dialog and asks `decidePress` to rule on
            // what it now says. A dialog that changed in between gets nothing
            // pressed — deciding by position here is what would let a
            // replacement dialog absorb the click (#89's hazard).
            var refusal: DialogDismissCommand.PressDecision?
            let outcome = press(observedWindowID, inspectionWindowID) { current in
                let decision = DialogDismissCommand.decidePress(
                    title: button, expected: dialog, current: current)
                if case .press(let index) = decision { return index }
                refusal = decision
                return nil
            }

            switch outcome {
            case .inspectionIncomplete:
                throw SafariBrowserError.dialogInspectionIncomplete
            case .pressed:
                // AXPress success means the action was dispatched, not that the
                // dialog closed — a page that queues several alerts puts the
                // next one up immediately. Say which happened rather than
                // letting "pressed" imply "gone".
                switch inspect(inspectionWindowID).scanResult {
                case .inspectionIncomplete:
                    print("pressed; could not re-check the inspection scope. Inspect Safari manually; do not repeat the press.")
                case .none:
                    if let inspectionWindowID { print("inspection scope: Safari window id \(inspectionWindowID)") }
                    print("pressed; no dialog remains")
                    DialogListCommand.reportVisibilityLimit()
                case .one(let still):
                    print("pressed; a dialog is still present: "
                          + BlockingDialogWarning.messageText(still))
                case .many:
                    print("pressed; more than one dialog is now present in the inspection scope; inspect Safari before another action")
                case .sessionLocked:
                    print("pressed; could not re-check: " + SafariBrowserError.guiSessionLocked.localizedDescription)
                case .sessionUnavailable:
                    print("pressed; could not re-check: " + SafariBrowserError.guiSessionUnavailable.localizedDescription)
                case .accessibilityDenied:
                    print("pressed; could not re-check (Accessibility no longer available)")
                }
            case .sessionLocked:
                throw SafariBrowserError.guiSessionLocked
            case .sessionUnavailable:
                throw SafariBrowserError.guiSessionUnavailable
            case .accessibilityDenied:
                throw SafariBrowserError.accessibilityRequired(flag: "dialog dismiss")
            case .noDialogFound:
                throw SafariBrowserError.dialogChangedBeforePress(nowMessage: "", nowButtons: [])
            case .ambiguous(let messages):
                throw SafariBrowserError.ambiguousBlockingDialog(messages: messages)
            case .refused(let current):
                if expectWindowID != nil { throw ValidationError(Self.expectationMismatch) }
                switch refusal {
                case .refuseButtonGone(let available):
                    throw SafariBrowserError.dialogButtonNotFound(titled: button, available: available)
                case .refuseAmbiguous(let title, let count):
                    throw SafariBrowserError.dialogButtonAmbiguous(titled: title, count: count)
                default:
                    throw SafariBrowserError.dialogChangedBeforePress(
                        nowMessage: current.message, nowButtons: current.buttons)
                }
            case .indexOutOfRange(let count):
                throw SafariBrowserError.dialogChangedBeforePress(
                    nowMessage: "resolved index outside the dialog's \(count) buttons",
                    nowButtons: [])
            case .pressUnconfirmed(let axError, let certainlyNotDelivered):
                throw SafariBrowserError.dialogPressUnconfirmed(
                    axError: axError, certainlyNotDelivered: certainlyNotDelivered)
            }
        }
    }
}
