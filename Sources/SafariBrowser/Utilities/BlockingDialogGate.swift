import Foundation

/// #126: what the entry-point probe found for the window a command targets.
///
/// `unprobed` is not `none`. It means nobody looked (probe disabled, target
/// not yet resolved, window not mappable) — and #89's rule that the absence of
/// a probe must never be reported as the absence of a dialog applies here too.
enum BlockingDialogState: Sendable, Equatable {
    case unprobed
    case accessibilityDenied
    case none
    case present(SafariBridge.BlockingDialog)
}

/// The one line every command prints first when a dialog is in the way.
///
/// Shared with `dialog list` so the two never describe the same dialog in two
/// vocabularies. One line by construction — internal newlines in the dialog's
/// own text are folded (verify round 2, B2) — so `head -1` sees all of it.
/// Honest limit: for a read-only command that succeeds, `2>&1 | tail -1`
/// still shows the command's stdout (it flushes last); what makes a blocked
/// tab visible in that pipeline is the JavaScript path failing non-zero with
/// this same text as its error, not this line. Control characters and length
/// are #114's job.
enum BlockingDialogWarning {
    static func firstLine(windowKey: BlockingDialogGate.WindowKey, dialog: SafariBridge.BlockingDialog) -> String {
        "⚠ BLOCKING DIALOG in \(windowKey.humanDescription): \(messageText(dialog))"
            + " — buttons: \(buttonsText(dialog)). Run: safari-browser dialog list"
    }

    /// The probe ran but found no AX window for the target — nobody looked.
    static func unmappableLine(windowKey: BlockingDialogGate.WindowKey) -> String {
        "⚠ dialog probe could not map \(windowKey.humanDescription) to an Accessibility window;"
            + " a blocking dialog there would go unnoticed — run: safari-browser dialog list"
    }

    static func probeUnavailableLine() -> String {
        "⚠ dialog probe unavailable (Accessibility not granted) — a blocking dialog would go unnoticed;"
            + " grant Accessibility or run: safari-browser setup"
    }

    /// Quoted dialog text, or an explicit stand-in. Saying nothing about an
    /// unreadable message would read as "no dialog" (see #127 for why the text
    /// can be missing even when the dialog is real).
    static func messageText(_ dialog: SafariBridge.BlockingDialog) -> String {
        let text = oneLine(dialog.message)
        return text.isEmpty ? "(no readable message)" : "\"\(text)\""
    }

    static func buttonsText(_ dialog: SafariBridge.BlockingDialog) -> String {
        dialog.buttons.isEmpty
            ? "(none exposed)"
            : dialog.buttons.map { "\"\(oneLine($0))\"" }.joined(separator: ", ")
    }

    /// Fold every line break (CR, LF, CRLF, U+2028/2029) into one space and
    /// collapse the runs, so page-controlled text cannot add a second line.
    static func oneLine(_ raw: String) -> String {
        let folded = raw.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}": return " "
            default: return String(scalar)
            }
        }.joined()
        return folded.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Process-wide memory of the entry-point probe (#126).
///
/// The bridge asks it once per resolved window; JavaScript dispatch asks it
/// whether to refuse. Everything that touches the outside world — the AX probe,
/// stderr, the environment, the clock — is injected so the decisions can be
/// tested without a Safari and without a dialog on screen.
final class BlockingDialogGate: @unchecked Sendable {

    /// Which window to probe, in the terms the target resolver already has.
    enum WindowKey: Hashable, Sendable {
        case front
        case index(Int)
        /// Safari's AppleScript `window id`, measured equal to the CGWindowID
        /// (#126: 2838 / 220 / 6097 / 438 / 11656 matched one for one).
        case id(Int)

        var humanDescription: String {
            switch self {
            case .front: return "front window"
            case .index(let n): return "window \(n)"
            case .id(let id): return "window id \(id)"
            }
        }
    }

    static let shared = BlockingDialogGate()

    /// Set to exactly `1` to disable the probe for batch scripts that accept
    /// the risk. Only that value counts (repo convention, `DaemonLog`): a
    /// script exporting `=0` must not switch a visibility mechanism off.
    /// What it switches off is all of #126 — the warning, the JavaScript
    /// fast-fail, and the "probe unavailable" notice.
    static let optOutVariable = "SAFARI_BROWSER_NO_DIALOG_PROBE"
    /// Set to print the probe's cost and verdict after the warning line.
    static let debugVariable = "SAFARI_BROWSER_DIALOG_PROBE_DEBUG"

    private let lock = NSLock()
    private let probe: (WindowKey) -> BlockingDialogState
    private let stderr: (String) -> Void
    private let environment: [String: String]
    private let now: () -> Date
    private let ttl: TimeInterval

    private var cache: [WindowKey: (state: BlockingDialogState, at: Date)] = [:]
    private var last: BlockingDialogState = .unprobed
    /// Two separate once-flags: a "could not probe" notice must never silence
    /// a later real dialog (verify round 2, I1).
    private var warnedPresent = false
    private var warnedUnavailable = false

    init(
        probe: ((WindowKey) -> BlockingDialogState)? = nil,
        stderr: ((String) -> Void)? = nil,
        environment: [String: String]? = nil,
        now: (() -> Date)? = nil,
        ttl: TimeInterval = 2
    ) {
        self.probe = probe ?? { SafariBridge.detectBlockingDialog(windowKey: $0) }
        self.stderr = stderr ?? { FileHandle.standardError.write(Data($0.utf8)) }
        self.environment = environment ?? ProcessInfo.processInfo.environment
        self.now = now ?? Date.init
        self.ttl = ttl
    }

    /// The most recent verdict, for the JavaScript gate and the failure paths.
    var current: BlockingDialogState {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// Probe (or reuse a fresh answer for) the window behind `key`, remember
    /// the verdict, and — the first time anything is in the way — say so on
    /// stderr before any other output.
    @discardableResult
    func check(_ key: WindowKey) -> BlockingDialogState {
        lock.lock(); defer { lock.unlock() }
        if environment[Self.optOutVariable] == "1" {
            last = .unprobed
            return last
        }
        let started = now()
        let state: BlockingDialogState
        let reused: Bool
        if let cached = cache[key], started.timeIntervalSince(cached.at) < ttl {
            state = cached.state
            reused = true
        } else {
            state = probe(key)
            cache[key] = (state, started)
            reused = false
        }
        last = state
        switch state {
        case .present(let dialog) where !warnedPresent:
            warnedPresent = true
            stderr(BlockingDialogWarning.firstLine(windowKey: key, dialog: dialog) + "\n")
        case .accessibilityDenied where !warnedUnavailable:
            warnedUnavailable = true
            stderr(BlockingDialogWarning.probeUnavailableLine() + "\n")
        case .unprobed where !warnedUnavailable && !reused:
            // A probe that actually ran and could not map the window. (A cache
            // hit is not a second sighting; the opt-out path never gets here.)
            warnedUnavailable = true
            stderr(BlockingDialogWarning.unmappableLine(windowKey: key) + "\n")
        case .present, .accessibilityDenied, .unprobed, .none:
            break
        }
        if environment[Self.debugVariable] == "1" {
            let ms = Int((now().timeIntervalSince(started) * 1000).rounded())
            stderr("dialog probe: \(key.humanDescription) \(reused ? "(cached)" : "\(ms) ms") → \(state.debugName)\n")
        }
        return state
    }

    /// JavaScript cannot run while a dialog holds the tab. Refuse now, with the
    /// same error the failure paths already use, instead of letting osascript
    /// discover it after its 30-second timeout.
    func throwIfBlocked() throws {
        if case .present(let dialog) = current {
            throw SafariBrowserError.javaScriptDialogBlocking(message: dialog.message, buttons: dialog.buttons)
        }
    }

    /// Forget everything — for tests and for long-lived processes that know
    /// the world changed (a dialog was just dismissed).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        last = .unprobed
        warnedPresent = false
        warnedUnavailable = false
    }
}

private extension BlockingDialogState {
    var debugName: String {
        switch self {
        case .unprobed: return "unprobed"
        case .accessibilityDenied: return "accessibility denied"
        case .none: return "none"
        case .present: return "present"
        }
    }
}
