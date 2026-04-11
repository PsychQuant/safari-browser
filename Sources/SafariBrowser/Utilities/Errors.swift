import Foundation

enum SafariBrowserError: LocalizedError {
    case appleScriptFailed(String)
    case fileNotFound(String)
    case invalidTabIndex(Int)
    case timeout(seconds: Int)
    case processTimedOut(command: String, seconds: Int)
    case invalidTimeout(Double)
    case systemEventsNotResponding(underlying: String)
    case documentNotFound(pattern: String, availableDocuments: [String])
    case noSafariWindow
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let message):
            return "AppleScript error: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidTabIndex(let index):
            return "Invalid tab index: \(index)"
        case .timeout(let seconds):
            return "Timeout after \(seconds) seconds"
        case .processTimedOut(let command, let seconds):
            return """
                Process timed out after \(seconds) seconds: \(command)
                Hint: if this recurs, check Console.app for System Events or Apple Event dispatcher issues.
                """
        case .invalidTimeout(let value):
            return "Invalid timeout value: \(value) (must be a finite number between 0.001 and 86400 seconds)"
        case .systemEventsNotResponding(let underlying):
            return """
                System Events is not responding. Keyboard-simulating commands (e.g. `upload --native`, `pdf`) cannot proceed.
                Try restarting it manually: killall "System Events" (launchd will relaunch it on the next Apple Event)
                Note: this will interrupt other active System Events automation (Keyboard Maestro, Alfred, Shortcuts, etc.).
                Underlying: \(underlying)
                """
        case .documentNotFound(let pattern, let availableDocuments):
            let listing: String
            if availableDocuments.isEmpty {
                listing = "  (no Safari documents are currently open)"
            } else {
                listing = availableDocuments.enumerated()
                    .map { "  [\($0.offset + 1)] \($0.element)" }
                    .joined(separator: "\n")
            }
            return """
                No Safari document matches "\(pattern)".
                Available documents:
                \(listing)
                Run `safari-browser documents` to list documents, or use a different --url / --window / --document value.
                """
        case .noSafariWindow:
            return "No Safari window found"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        }
    }
}
