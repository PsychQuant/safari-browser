import CoreGraphics
import Foundation

/// Session availability is independent of Accessibility and Screen Recording
/// permission. A locked session can return AX placeholders instead of windows.
struct GUISession: Sendable {
    enum State: Sendable, Equatable {
        case available
        case locked
        case unavailable
    }

    static let live = GUISession {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }

    let readDictionary: @Sendable () -> [String: Any]?

    var state: State {
        guard let dictionary = readDictionary() else { return .unavailable }
        if dictionary["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        if dictionary[kCGSessionOnConsoleKey as String] as? Bool == false
            || dictionary[kCGSessionLoginDoneKey as String] as? Bool == false {
            return .unavailable
        }
        return .available
    }

    func requireAvailable() throws {
        switch state {
        case .available: return
        case .locked: throw SafariBrowserError.guiSessionLocked
        case .unavailable: throw SafariBrowserError.guiSessionUnavailable
        }
    }
}
