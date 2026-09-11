import Foundation

/// #126: what the entry-point probe found for the window a command targets.
///
/// `unprobed` is not `clear`: there is no complete observation (probe disabled,
/// target unresolved, window unreadable, or traversal incomplete). Failed reads,
/// time limits, and truncated branches never establish the absence of a dialog.
enum BlockingDialogState: Sendable, Equatable {
    case unprobed
    case accessibilityDenied
    case clear
    case present(SafariBridge.BlockingDialog)
}

/// The line a command that resolves through the shared document resolver
/// prints on stderr when a dialog is in the way — the first line it writes
/// itself (a `--tab` notice or `--first-match` summary can precede it; the
/// native-target commands share the same gate).
///
/// Shared with `dialog list` so the two never describe the same dialog in two
/// vocabularies. One line by construction — line separators in the dialog's
/// own text are folded (verify round 2, B2) — so `head -1` sees all of it.
/// Honest limit: `2>&1 | tail -1` is not rescued by this line. For a
/// read-only command that succeeds it shows the command's stdout (it flushes
/// last), and for the JavaScript path the last line of the error is its
/// closing sentence, not the dialog's text. Preserving the upstream non-zero
/// exit requires `set -o pipefail` or inspecting the upstream command status;
/// otherwise the pipeline reports `tail`'s status. Control characters, quoting
/// and length are #114's job.
enum BlockingDialogWarning {
    static func firstLine(windowKey: BlockingDialogGate.WindowKey, dialog: SafariBridge.BlockingDialog) -> String {
        "⚠ BLOCKING DIALOG in \(windowKey.humanDescription): \(messageText(dialog))"
            + " — buttons: \(buttonsText(dialog)). Run: safari-browser dialog list"
    }

    /// The probe could not establish a complete answer for this target.
    static func unmappableLine(windowKey: BlockingDialogGate.WindowKey) -> String {
        "⚠ dialog probe could not inspect \(windowKey.humanDescription) completely;"
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

    /// Fold the seven scalars Foundation's `.newlines` counts as line breaks —
    /// LF, VT, FF, CR, NEL (U+0085), LS (U+2028), PS (U+2029) — into one space
    /// and collapse the runs (which also collapses pre-existing double spaces),
    /// so page-controlled text cannot add a second line.
    static func oneLine(_ raw: String) -> String {
        let folded = raw.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\n", "\u{000B}", "\u{000C}", "\r", "\u{0085}", "\u{2028}", "\u{2029}": return " "
            default: return String(scalar)
            }
        }.joined()
        return folded.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Target-keyed memory of entry probes, scoped to the CLI or daemon request.
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

    private static let processGate = BlockingDialogGate()
    static var shared: BlockingDialogGate {
        DaemonRequestContext.current?.gate ?? processGate
    }

    /// Set to exactly `1` to disable the probe for batch scripts that accept
    /// the risk. Only that value counts (repo convention, `DaemonLog`): a
    /// script exporting `=0` must not switch a visibility mechanism off.
    /// What it switches off is all of #126 — the warning, the JavaScript
    /// fast-fail, and the "probe unavailable" notice.
    static let optOutVariable = "SAFARI_BROWSER_NO_DIALOG_PROBE"
    /// Set to exactly `1` to print the probe's cost and verdict after the
    /// warning line.
    static let debugVariable = "SAFARI_BROWSER_DIALOG_PROBE_DEBUG"

    private let lock = NSLock()
    private let probe: (WindowKey, TimeInterval) -> BlockingDialogState
    private let stderr: (String) -> Void
    private let environment: [String: String]
    private let now: () -> TimeInterval
    private let ttl: TimeInterval

    private var cache: [WindowKey: (state: BlockingDialogState, at: TimeInterval)] = [:]
    // A newer check or reset must invalidate work that was started earlier.
    private var generation: UInt64 = 0
    private var latestProbe: [WindowKey: UInt64] = [:]
    /// Two separate once-flags: a "could not probe" notice must never silence
    /// a later real dialog (verify round 2, I1).
    private static let commandBudget: TimeInterval = 0.2
    private static let singleProbeBudget: TimeInterval = 0.1
    private var budgetCommitted: TimeInterval = 0
    private var budgetEpoch: UInt64 = 0
    private var warnedPresent = false
    private var warnedUnavailable = false

    init(
        probe: ((WindowKey) -> BlockingDialogState)? = nil,
        stderr: ((String) -> Void)? = nil,
        environment: [String: String]? = nil,
        now: (() -> TimeInterval)? = nil,
        ttl: TimeInterval = 2
    ) {
        if let probe { self.probe = { key, _ in probe(key) } }
        else { self.probe = { key, budget in SafariBridge.detectBlockingDialog(windowKey: key, budget: budget) } }
        self.stderr = stderr ?? { FileHandle.standardError.write(Data($0.utf8)) }
        self.environment = environment ?? ProcessInfo.processInfo.environment
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        self.ttl = ttl
    }

    /// A query never performs AX work and never borrows another window's answer.
    func state(for key: WindowKey) -> BlockingDialogState {
        let timestamp = now()
        return lock.withLock {
            guard environment[Self.optOutVariable] != "1", let cached = cache[key],
                  timestamp >= cached.at, timestamp - cached.at < ttl else {
                cache.removeValue(forKey: key)
                return .unprobed
            }
            return cached.state
        }
    }

    /// Keep the short state lock away from AX work: the bounded worker may be
    /// waiting on an unresponsive application while other windows need a result.
    @discardableResult
    func check(_ key: WindowKey, forceRefresh: Bool = false) -> BlockingDialogState {
        guard environment[Self.optOutVariable] != "1" else { return .unprobed }
        let started = now()
        let lookup: (cached: BlockingDialogState?, token: UInt64, reserved: TimeInterval, epoch: UInt64) = lock.withLock {
            if !forceRefresh, let cached = cache[key],
               started >= cached.at, started - cached.at < ttl {
                return (cached.state, 0, 0, budgetEpoch)
            }
            generation &+= 1
            latestProbe[key] = generation
            cache.removeValue(forKey: key)
            let available = max(0, Self.commandBudget - budgetCommitted)
            let reserved = available >= 0.001 ? min(Self.singleProbeBudget, available) : 0
            budgetCommitted += reserved
            return (nil, generation, reserved, budgetEpoch)
        }
        let result: BlockingDialogState
        let reused = lookup.cached != nil
        if let cached = lookup.cached {
            result = cached
        } else {
            // Keep a small margin for returning and accounting; real AX work
            // is bounded by the worker. A zero budget never calls the provider.
            let observed = lookup.reserved > 0
                ? probe(key, max(0, lookup.reserved - 0.001)) : .unprobed
            let finished = now()
            let accepted: BlockingDialogState? = lock.withLock {
                if budgetEpoch == lookup.epoch {
                    let elapsed = lookup.reserved > 0 ? max(0, finished - started) : 0
                    budgetCommitted = max(0, budgetCommitted - lookup.reserved + elapsed)
                }
                guard latestProbe[key] == lookup.token else { return nil }
                let fresh = finished >= started && finished - started < ttl
                let state: BlockingDialogState = fresh ? observed : .unprobed
                cache[key] = (state, started)
                return state
            }
            guard let accepted else { return .unprobed }
            result = accepted
        }
        let messages: [String] = lock.withLock {
            var lines: [String] = []
            switch result {
            case .present(let dialog) where !warnedPresent:
                warnedPresent = true
                lines.append(BlockingDialogWarning.firstLine(windowKey: key, dialog: dialog) + "\n")
            case .accessibilityDenied where !warnedUnavailable:
                warnedUnavailable = true
                lines.append(BlockingDialogWarning.probeUnavailableLine() + "\n")
            case .unprobed where !warnedUnavailable && !reused:
                warnedUnavailable = true
                lines.append(BlockingDialogWarning.unmappableLine(windowKey: key) + "\n")
            case .present, .accessibilityDenied, .unprobed, .clear:
                break
            }
            return lines
        }
        // Writers may inspect the gate; never invoke injected code under its lock.
        for message in messages { stderr(message) }
        if environment[Self.debugVariable] == "1" {
            let ms = Int((max(0, now() - started) * 1000).rounded())
            stderr("dialog probe: \(key.humanDescription) \(reused ? "(cached)" : "\(ms) ms") → \(result.debugName)\n")
        }
        return result
    }

    /// Refuse JavaScript only on current evidence for this exact target.
    func throwIfBlocked(_ key: WindowKey) throws {
        if case .present(let dialog) = state(for: key) {
            throw SafariBrowserError.javaScriptDialogBlocking(message: dialog.message, buttons: dialog.buttons)
        }
    }

    /// Each daemon exec step is a logical command, just like its subprocess
    /// counterpart. Refresh evidence and its budget, retaining request warnings.
    func beginCommand() {
        lock.withLock {
            cache.removeAll()
            latestProbe.removeAll()
            budgetCommitted = 0
            budgetEpoch &+= 1
        }
    }

    /// A dialog dismissal invalidates cached and in-flight observations alike.
    func reset() {
        lock.withLock {
            cache.removeAll()
            latestProbe.removeAll()
            budgetCommitted = 0
            budgetEpoch &+= 1
            warnedPresent = false
            warnedUnavailable = false
        }
    }
}

private extension BlockingDialogState {
    var debugName: String {
        switch self {
        case .unprobed: return "unprobed"
        case .accessibilityDenied: return "accessibility denied"
        case .clear: return "clear"
        case .present: return "present"
        }
    }
}
