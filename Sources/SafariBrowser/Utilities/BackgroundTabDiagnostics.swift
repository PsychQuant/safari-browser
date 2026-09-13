import Foundation

/// Coordinates retained from target resolution, never inferred from current focus.
struct BackgroundTabDiagnosticTarget: Sendable {
    let windowID: Int
    let tabIndex: Int
    let matcher: SafariBridge.UrlMatcher?
}

enum BackgroundTabDiagnostics {
    enum Observation: Equatable {
        case current, background, unknown
    }

    @TaskLocal static var query: (@Sendable (String) async throws -> String)?

    static func script(for target: BackgroundTabDiagnosticTarget) -> String? {
        guard target.windowID > 0, target.tabIndex > 0 else { return nil }
        // Only numeric coordinates enter this script; the matcher stays in Swift.
        return """
        if not (application "Safari" is running) then return ""
        tell application "Safari"
            tell window id \(target.windowID)
                set tabCount to count of tabs
                set currentIndex to index of current tab
                set targetURL to URL of tab \(target.tabIndex)
                if targetURL is missing value then return ""
                set GS to character id 29
                return (currentIndex as text) & GS & (tabCount as text) & GS & targetURL
            end tell
        end tell
        """
    }

    static func inspect(_ target: BackgroundTabDiagnosticTarget?) async -> Observation {
        guard let target, let source = script(for: target) else { return .unknown }
        do {
            let output: String
            if let query {
                output = try await query(source)
            } else {
                // A busy daemon AppleScript executor must not queue this diagnostic.
                // The process runner adds at most its existing 1s SIGKILL grace.
                output = try await SafariBridge.runShell(
                    "/usr/bin/osascript", ["-e", source], timeout: 0.3)
            }
            let fields = output.split(separator: "\u{1D}", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let currentIndex = Int(fields[0]), String(currentIndex) == fields[0],
                  let tabCount = Int(fields[1]), String(tabCount) == fields[1],
                  currentIndex > 0, currentIndex <= tabCount,
                  target.tabIndex <= tabCount,
                  !fields[2].isEmpty else { return .unknown }
            if let matcher = target.matcher, !matcher.matches(String(fields[2])) {
                return .unknown
            }
            return currentIndex == target.tabIndex ? .current : .background
        } catch {
            // This optional observation must never replace the original command result.
            return .unknown
        }
    }

    static func warning(for observation: Observation) -> String? {
        guard observation == .background else { return nil }
        return """
        Warning: the resolved target was in the background when checked. A pending dialog \
        may be hidden; this observation does not prove that a dialog exists. Recheck the \
        target, run `safari-browser tab focus` with the same target flags, then run `safari-browser dialog list`.
        """
    }
}
