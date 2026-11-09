import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #354: a fake Safari whose window ORDER changes during a command. Windows are listed front to back; the
/// first is Safari's `window 1`. It answers the anchor reads (`set _id to id of window N` /
/// `set _id to <id>`), the enumeration, and every script that names `window id W`; any other script gets
/// `answer`. Knobs:
/// - `raiseAfterScripts = k`: after the k-th script, the LAST window is moved to the front, so every
///   position names another window from then on.
/// - `closeAfterScripts = (k, id)`: after the k-th script, window `id` closes.
/// - `withoutIDs`: the enumeration carries no window ids (a legacy record).
final class PinFakeSafari: @unchecked Sendable {
    typealias Window = (id: Int, profile: String, tabs: [String])

    private let lock = NSLock()
    private var order: [Window]
    private var sent: [String] = []
    var raiseAfterScripts: Int?
    var closeAfterScripts: (count: Int, id: Int)?
    var withoutIDs = false
    var answer = "OK"

    /// Window 1 = id 4711 (Home, three tabs), window 2 = id 5822 (Work, two tabs), window 3 = id 6933 (Work, one tab).
    static let threeWindows: [Window] = [
        (4711, "Home", ["https://home.example/1", "https://home.example/2", "https://home.example/3"]),
        (5822, "Work", ["https://work.example/a1", "https://work.example/a2"]),
        (6933, "Work", ["https://work.example/b1"]),
    ]

    init(windows: [Window] = PinFakeSafari.threeWindows) { order = windows }

    var scripts: [String] { lock.withLock { sent } }
    var transcript: String { scripts.joined(separator: "\n---\n") }

    func drive<T>(_ body: () async throws -> T) async throws -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try self.respond($0) }) {
                    try await body()
                }
            }
        }
    }

    /// Runs a parsed command against the fake; an error the command throws is returned, not thrown.
    @discardableResult
    func run<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String]) async -> Error? {
        do {
            var command = try C.parse(args)
            try await drive { try await command.run() }
            return nil
        } catch {
            return error
        }
    }

    private static func int(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func notFound(_ what: String) -> SafariBrowserError {
        .appleScriptFailed("execution error: Can’t get \(what). (-1728)")
    }

    func respond(_ script: String) throws -> String {
        let (windows, count) = lock.withLock { () -> ([Window], Int) in
            sent.append(script)
            return (order, sent.count)
        }
        defer { afterScript(count) }

        if script.contains("set windowCount to count of windows") {
            let gs = "\u{1D}", rs = "\u{1E}"
            var out = ""
            for (i, window) in windows.enumerated() {
                for (j, url) in window.tabs.enumerated() {
                    out += ["\(i + 1)", "\(j + 1)", j == 0 ? "1" : "0", url, "Tab \(j + 1)",
                            "\(window.profile) — Tab 1", withoutIDs ? "" : "\(window.id)"].joined(separator: gs) + rs
                }
            }
            return out
        }
        // `windowAnchorScript(index:)` / `tabAnchorScript(windowIndex:)`.
        if let n = Self.int(after: "set _id to id of window ", in: script) {
            guard n >= 1, n <= windows.count else {
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get window \(n). Invalid index. (-1719)")
            }
            return try anchor(windows[n - 1], script: script)
        }
        // `windowAnchorScript(windowID:)` / `tabAnchorScript(windowID:)`.
        if let id = Self.int(after: "set _id to ", in: script) {
            guard let window = windows.first(where: { $0.id == id }) else { throw Self.notFound("window id \(id)") }
            return try anchor(window, script: script)
        }
        if let id = Self.int(after: "window id ", in: script) {
            guard let window = windows.first(where: { $0.id == id }) else { throw Self.notFound("window id \(id)") }
            if let tab = Self.int(after: "tab ", in: script), script.contains("tab \(tab) of window id"),
               tab > window.tabs.count {
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get tab \(tab). Invalid index. (-1719)")
            }
            if script.contains("URL of") { return window.tabs.first ?? "" }
            return answer
        }
        if script.contains("count of windows") && !script.contains("of window ") {
            return "\(windows.count)"
        }
        return answer
    }

    private func anchor(_ window: Window, script: String) throws -> String {
        if script.contains("count of tabs of window id _id") {
            guard !window.tabs.isEmpty else { throw Self.notFound("tab") }
            return "\(window.id)\u{1D}\(window.tabs.count)"
        }
        guard !window.tabs.isEmpty else { throw Self.notFound("current tab of window id \(window.id)") }
        return "\(window.id)\u{1D}1"
    }

    private func afterScript(_ count: Int) {
        lock.withLock {
            if raiseAfterScripts == count, let last = order.popLast() { order.insert(last, at: 0) }
            if let close = closeAfterScripts, close.count == count { order.removeAll { $0.id == close.id } }
        }
    }

    /// The scripts sent after the first one that `isPin` accepts (the pin itself excluded).
    func scripts(afterFirst isPin: (String) -> Bool) -> [String] {
        let all = scripts
        guard let first = all.firstIndex(where: isPin) else { return [] }
        return Array(all[(first + 1)...])
    }

    static func isIndexAnchor(_ script: String) -> Bool { script.contains("set _id to id of window ") }
    static func isEnumeration(_ script: String) -> Bool { script.contains("set windowCount to count of windows") }
}
