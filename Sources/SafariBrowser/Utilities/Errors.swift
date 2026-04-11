import Foundation

enum SafariBrowserError: LocalizedError {
    case appleScriptFailed(String)
    case fileNotFound(String)
    case invalidTabIndex(Int)
    case timeout(seconds: Int)
    case processTimedOut(command: String, seconds: Int)
    case invalidTimeout(Double)
    case systemEventsNotResponding(underlying: String)
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
                System Events is not responding. Keyboard-simulating commands (upload --native, navigateFileDialog) cannot proceed.
                Try restarting it manually: killall "System Events" && sleep 1 (launchd will relaunch it on next Apple Event)
                Underlying: \(underlying)
                """
        case .noSafariWindow:
            return "No Safari window found"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        }
    }
}
