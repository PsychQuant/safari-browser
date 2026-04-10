import Foundation

enum SafariBrowserError: LocalizedError {
    case appleScriptFailed(String)
    case fileNotFound(String)
    case invalidTabIndex(Int)
    case timeout(seconds: Int)
    case processTimedOut(command: String, seconds: Int)
    case invalidTimeout(Double)
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
            return "Invalid timeout value: \(value) (must be a finite positive number)"
        case .noSafariWindow:
            return "No Safari window found"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        }
    }
}
