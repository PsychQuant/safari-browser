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
        guard AXIsProcessTrusted() else {
            throw SafariBrowserError.accessibilityRequired(flag: "dialog list")
        }
        guard let dialog = SafariBridge.detectBlockingDialog() else {
            print(DialogListCommand.noDialogMessage)
            return
        }
        print(DialogListCommand.describe(dialog))
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

    func run() async throws {
        guard AXIsProcessTrusted() else {
            throw SafariBrowserError.accessibilityRequired(flag: "dialog dismiss")
        }
        guard let dialog = SafariBridge.detectBlockingDialog() else {
            throw ValidationError(DialogListCommand.noDialogMessage)
        }

        switch DialogDismissCommand.selectButton(titled: button, from: dialog.buttons) {
        case .notFound(let available):
            throw ValidationError("""
                no button titled "\(button)" on this dialog.
                Present: \(available.isEmpty ? "(none exposed)" : available.map { "\"\($0)\"" }.joined(separator: ", "))
                Titles are localized — copy one from `safari-browser dialog list`.
                """)

        case .ambiguous(let title, let count):
            throw ValidationError("""
                this dialog has \(count) buttons titled "\(title)"; refusing to guess which one you meant.
                Pressing an arbitrary one is the un-asked-for action this command exists to avoid.
                """)

        case .found(let index):
            print(DialogDismissCommand.preamble(for: dialog, pressing: button))
            switch SafariBridge.pressDialogButton(atIndex: index) {
            case .pressed:
                print("pressed")
            case .noDialogFound:
                throw ValidationError(
                    "the dialog disappeared before it could be pressed — nothing was clicked")
            case .indexOutOfRange(let count):
                throw ValidationError(
                    "the dialog changed while resolving the button (now \(count) buttons) — nothing was clicked")
            case .pressFailed(let axError):
                throw ValidationError(
                    "Accessibility refused the press (AXError \(axError)) — the dialog is unchanged")
            }
        }
    }
}
