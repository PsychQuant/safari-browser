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

    /// Rendered separately from the printing so the wording is testable.
    static func describe(_ dialog: SafariBridge.BlockingDialog) -> String {
        let text = dialog.message.trimmingCharacters(in: .whitespacesAndNewlines)
        // A dialog with no readable text still blocks. Saying nothing about the
        // message would read as "no dialog", which is the opposite of the truth.
        let messageLine = text.isEmpty
            ? "message: (no readable text — the dialog exposes none)"
            : "message: \(text)"
        let buttonLine = dialog.buttons.isEmpty
            ? "buttons: (none exposed)"
            : "buttons: " + dialog.buttons.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            blocking dialog present
              \(messageLine)
              \(buttonLine)

            To dismiss it, name the button:
              safari-browser dialog dismiss --button "<title>"
            """
    }

    static let noDialogMessage = "no blocking dialog found"

    func run() async throws {
        switch SafariBridge.scanBlockingDialogs() {
        case .accessibilityDenied:
            throw SafariBrowserError.accessibilityRequired(flag: "dialog list")
        case .none:
            print(DialogListCommand.noDialogMessage)
        case .one(let dialog):
            print(DialogListCommand.describe(dialog))
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
        let text = dialog.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            dismissing dialog
              message: \(text.isEmpty ? "(no readable text)" : text)
              pressing: "\(button)"
            """
    }

    /// A title that trims to nothing names no button — but `selectButton`
    /// trims both sides, so `--button ""` would match a button whose title is
    /// whitespace, and Foundation's whitespace set includes characters like
    /// U+00A0 and U+200B that render as an ordinary-looking blank. `dialog list`
    /// shows such a button as `""`, so the user cannot even see what they would
    /// be pressing. Rejected at parse time rather than handled later.
    func validate() throws {
        if button.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError(
                "--button needs the button's title. An empty or whitespace-only value names "
                + "nothing, and this command never presses a button you did not name.")
        }
    }

    func run() async throws {
        let dialog: SafariBridge.BlockingDialog
        switch SafariBridge.scanBlockingDialogs() {
        case .accessibilityDenied:
            throw SafariBrowserError.accessibilityRequired(flag: "dialog dismiss")
        case .none:
            throw SafariBrowserError.noBlockingDialog
        case .many(let messages):
            throw SafariBrowserError.ambiguousBlockingDialog(messages: messages)
        case .one(let d):
            dialog = d
        }

        switch DialogDismissCommand.selectButton(titled: button, from: dialog.buttons) {
        case .notFound(let available):
            throw SafariBrowserError.dialogButtonNotFound(titled: button, available: available)
        case .ambiguous(let title, let count):
            throw SafariBrowserError.dialogButtonAmbiguous(titled: title, count: count)
        case .found:
            print(DialogDismissCommand.preamble(for: dialog, pressing: button))

            // The press re-reads the dialog and asks `decidePress` to rule on
            // what it now says. A dialog that changed in between gets nothing
            // pressed — deciding by position here is what would let a
            // replacement dialog absorb the click (#89's hazard).
            var refusal: DialogDismissCommand.PressDecision?
            let outcome = SafariBridge.pressDialogButton { current in
                let decision = DialogDismissCommand.decidePress(
                    title: button, expected: dialog, current: current)
                if case .press(let index) = decision { return index }
                refusal = decision
                return nil
            }

            switch outcome {
            case .pressed:
                // AXPress success means the action was dispatched, not that the
                // dialog closed — a page that queues several alerts puts the
                // next one up immediately. Say which happened rather than
                // letting "pressed" imply "gone".
                switch SafariBridge.scanBlockingDialogs() {
                case .none:
                    print("pressed; no dialog remains")
                case .one(let still):
                    print("pressed; a dialog is still present: "
                          + (still.message.isEmpty ? "(no readable text)" : still.message))
                case .many:
                    print("pressed; more than one dialog is now present — run `dialog list`")
                case .accessibilityDenied:
                    print("pressed; could not re-check (Accessibility no longer available)")
                }
            case .accessibilityDenied:
                throw SafariBrowserError.accessibilityRequired(flag: "dialog dismiss")
            case .noDialogFound:
                throw SafariBrowserError.dialogChangedBeforePress(nowMessage: "", nowButtons: [])
            case .ambiguous(let messages):
                throw SafariBrowserError.ambiguousBlockingDialog(messages: messages)
            case .refused(let current):
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
