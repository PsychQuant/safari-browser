import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353: a fake Safari that *applies* what the window-level commands send.
///
/// `PinFakeSafari` answers reads; it has no notion of which tab is current and nothing ever closes in it. The
/// window-level commands are about exactly that: which tab was closed, whether the visible tab changed, whether
/// a window was raised. This fake keeps the windows in order (the first is Safari's `window 1`), a current tab
/// per window, and interprets the statements those commands send, line by line:
///
/// - `set _t to tab T of <window>` binds a tab, or fails as Safari does (-1728 for a window that is gone,
///   -1719 for a tab that is not there);
/// - the URL checks (`if (URL of _t) does not contain / is not equal to / does not end with / does not start
///   with "…" then error "SB_TARGET_CHANGED" number 9001`) are evaluated, case-sensitively, against the URL
///   that tab shows now;
/// - `close _t`, `close current tab of <window>`, `set current tab of <window> to _t`, `set index of <window>
///   to 1` and `activate` change the state and are recorded in `actions`.
///
/// It never runs a file-dialog script: those go straight to `osascript` in the product, and the tests stop at
/// the text.
final class WindowLevelFakeSafari: @unchecked Sendable {

    struct Window: Equatable {
        var id: Int
        var profile: String
        var tabs: [String]
        /// 1-based.
        var current = 1
    }

    /// Something the fake did because a script said so.
    enum Action: Equatable {
        case closed(windowID: Int, tab: Int, url: String)
        case madeCurrent(windowID: Int, tab: Int)
        case raised(windowID: Int)
        case activated
    }

    /// Window 1 = id 4711 (Home, three tabs), window 2 = id 5822 (Work, two tabs), window 3 = id 6933 (Work,
    /// one tab); tab 1 is current in each. The fixture the spec's Examples describe.
    static let threeWindows: [Window] = [
        Window(id: 4711, profile: "Home", tabs: ["https://home.example/1", "https://home.example/2", "https://home.example/3"]),
        Window(id: 5822, profile: "Work", tabs: ["https://work.example/a1", "https://work.example/a2"]),
        Window(id: 6933, profile: "Work", tabs: ["https://work.example/b1"]),
    ]

    private let lock = NSLock()
    private var order: [Window]
    private var sent: [String] = []
    private var done: [Action] = []
    private var afterScript: [Int: (inout [Window]) -> Void] = [:]
    /// The anchor read `pinWindowAtStart` makes does not answer.
    var anchorDoesNotAnswer = false
    /// What a `do JavaScript` returns.
    var javaScriptResult = "OK"

    init(windows: [Window] = WindowLevelFakeSafari.threeWindows) { order = windows }

    var scripts: [String] { lock.withLock { sent } }
    var transcript: String { scripts.joined(separator: "\n---\n") }
    var actions: [Action] { lock.withLock { done } }
    var windows: [Window] { lock.withLock { order } }
    func window(id: Int) -> Window? { windows.first { $0.id == id } }
    var closed: [Action] { actions.filter { if case .closed = $0 { return true }; return false } }

    /// Change the windows right after the `count`-th script was answered.
    func after(script count: Int, _ change: @escaping (inout [Window]) -> Void) {
        lock.withLock { afterScript[count] = change }
    }

    var diagnostics: [String] { context.diagnostics }
    private lazy var context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])

    func drive<T>(_ body: () async throws -> T) async throws -> T {
        let context = lock.withLock { self.context }
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

    // MARK: - Scripts

    static func isAnchor(_ script: String) -> Bool { script.contains("set _id to ") }
    static func isEnumeration(_ script: String) -> Bool { script.contains("set windowCount to count of windows") }

    /// The scripts sent after the first one `isFirst` accepts (that one excluded).
    func scripts(afterFirst isFirst: (String) -> Bool) -> [String] {
        let all = scripts
        guard let first = all.firstIndex(where: isFirst) else { return [] }
        return Array(all[(first + 1)...])
    }

    private static let positional = try! NSRegularExpression(pattern: #"window (?!id )[0-9]"#)
    /// `window 2`, `of window 3`: a window named by its position. `window id 5822` is not.
    static func namesAPosition(_ script: String) -> Bool {
        positional.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) != nil
    }

    private struct Failure: Error { let message: String }

    private static func notFound(_ what: String) -> SafariBrowserError {
        .appleScriptFailed("execution error: Can’t get \(what). (-1728)")
    }

    private static func invalidIndex(_ what: String) -> SafariBrowserError {
        .appleScriptFailed("execution error: Can’t get \(what). Invalid index. (-1719)")
    }

    private static func int(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    func respond(_ script: String) throws -> String {
        try lock.withLock {
            sent.append(script)
            let count = sent.count
            defer { if let change = afterScript[count] { change(&order) } }
            return try answer(script)
        }
    }

    private func answer(_ script: String) throws -> String {
        if Self.isEnumeration(script) {
            return FakeEnumeration.sourceForm(order.map {
                .titledTabs(id: $0.id, profile: $0.profile, urls: $0.tabs, currentTab: $0.current)
            })
        }
        if let id = Self.int(after: "get index of window id ", in: script) {
            guard let index = order.firstIndex(where: { $0.id == id }) else { throw Self.notFound("window id \(id)") }
            return "\(index + 1)"
        }
        if Self.isAnchor(script) {
            if anchorDoesNotAnswer {
                throw SafariBrowserError.appleScriptFailed("execution error: Safari got an error: AppleEvent timed out. (-1712)")
            }
            let window: Window
            if let n = Self.int(after: "set _id to id of window ", in: script) {
                guard n >= 1, n <= order.count else { throw Self.invalidIndex("window \(n)") }
                window = order[n - 1]
            } else if let id = Self.int(after: "set _id to ", in: script), let found = order.first(where: { $0.id == id }) {
                window = found
            } else {
                throw Self.notFound("window")
            }
            guard !window.tabs.isEmpty else { throw Self.notFound("current tab of window id \(window.id)") }
            let second = script.contains("count of tabs of window id _id") ? window.tabs.count : window.current
            return "\(window.id)\u{1D}\(second)"
        }
        if let n = Self.int(after: "to get id of window ", in: script) {
            guard n >= 1, n <= order.count else { throw Self.invalidIndex("window \(n)") }
            return "\(order[n - 1].id)"
        }
        return try interpret(script)
    }

    /// Index into `order` of the window a reference names: `window id W`, `window N`, `front window`.
    private func windowIndex(in text: String) throws -> Int? {
        if let id = Self.int(after: "window id ", in: text) {
            guard let index = order.firstIndex(where: { $0.id == id }) else { throw Self.notFound("window id \(id)") }
            return index
        }
        if text.contains("front window") {
            guard !order.isEmpty else { throw Self.invalidIndex("window 1") }
            return 0
        }
        if let n = Self.int(after: "window ", in: text) {
            guard n >= 1, n <= order.count else { throw Self.invalidIndex("window \(n)") }
            return n - 1
        }
        return nil
    }

    private static func literal(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close else { return nil }
        return String(text[text.index(after: open)..<close])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func interpret(_ script: String) throws -> String {
        var bound: (window: Int, tab: Int)?
        var skipping = false
        var result = "OK"

        func condition(_ text: String) throws -> Bool {
            if text == "(count of windows) = 0" { return order.isEmpty }
            if text.hasPrefix("(count of tabs of "), text.hasSuffix(") = 0") {
                guard let index = try windowIndex(in: text) else { return false }
                return order[index].tabs.isEmpty
            }
            if text.hasPrefix("not (exists window id ") {
                guard let id = Self.int(after: "window id ", in: text) else { return false }
                return !order.contains { $0.id == id }
            }
            if text.hasPrefix("(URL of _t) ") {
                guard let bound, let expected = Self.literal(in: text) else {
                    throw Failure(message: "a URL check on a tab that was never bound:\n\(script)")
                }
                let url = order[bound.window].tabs[bound.tab - 1]
                if text.contains("does not contain") { return !url.contains(expected) }
                if text.contains("is not equal to") { return url != expected }
                if text.contains("does not end with") { return !url.hasSuffix(expected) }
                if text.contains("does not start with") { return !url.hasPrefix(expected) }
                throw Failure(message: "a URL check this fake does not know: \(text)")
            }
            return false
        }

        func close(window index: Int, tab: Int) {
            let url = order[index].tabs.remove(at: tab - 1)
            done.append(.closed(windowID: order[index].id, tab: tab, url: url))
            if tab < order[index].current { order[index].current -= 1 }
            order[index].current = max(1, min(order[index].current, order[index].tabs.count))
        }

        func execute(_ line: String) throws {
            if line.hasPrefix("error ") {
                let message = Self.literal(in: line.components(separatedBy: " number ").first ?? line) ?? line
                let number = Self.int(after: " number ", in: line) ?? -2700
                throw SafariBrowserError.appleScriptFailed("execution error: \(message) (\(number))")
            }
            if line.hasPrefix("set _t to tab ") {
                guard let tab = Self.int(after: "set _t to tab ", in: line), let index = try windowIndex(in: line) else { return }
                guard tab >= 1, tab <= order[index].tabs.count else { throw Self.invalidIndex("tab \(tab)") }
                bound = (index, tab)
                return
            }
            if line == "close _t" {
                guard let bound else { throw Failure(message: "close _t with no tab bound:\n\(script)") }
                close(window: bound.window, tab: bound.tab)
                return
            }
            if line.hasPrefix("close current tab of ") {
                guard let index = try windowIndex(in: line) else { return }
                guard !order[index].tabs.isEmpty else { throw Self.notFound("current tab") }
                close(window: index, tab: order[index].current)
                return
            }
            if line.hasPrefix("set current tab of "), line.hasSuffix(" to _t") {
                guard let bound else { throw Failure(message: "set current tab with no tab bound:\n\(script)") }
                _ = try windowIndex(in: line)
                order[bound.window].current = bound.tab
                done.append(.madeCurrent(windowID: order[bound.window].id, tab: bound.tab))
                return
            }
            if line.hasPrefix("set index of "), line.hasSuffix(" to 1") {
                guard let index = try windowIndex(in: line) else { return }
                let window = order.remove(at: index)
                order.insert(window, at: 0)
                if let tab = bound, tab.window == index { bound = (0, tab.tab) }
                done.append(.raised(windowID: window.id))
                return
            }
            if line == "activate" {
                done.append(.activated)
                return
            }
            if line.hasPrefix("set b to bounds of ") {
                guard let index = try windowIndex(in: line) else { return }
                result = "0,25,1200,900\u{1F}Tab \(order[index].current)"
                return
            }
            if line.hasPrefix("get URL of ") || line.hasPrefix("return URL of ") {
                guard let index = try windowIndex(in: line) else { return }
                // `tab 2 of window id W` names a tab; `document of …` and `current tab of …` are the current one.
                let tab = Self.int(after: "tab ", in: line) ?? order[index].current
                guard tab >= 1, tab <= order[index].tabs.count else { throw Self.invalidIndex("tab \(tab)") }
                result = order[index].tabs[tab - 1]
                return
            }
            // Any other statement that names a window fails when that window is not there.
            _ = try windowIndex(in: line)
        }

        for raw in script.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if skipping {
                if line == "end if" { skipping = false }
                continue
            }
            if line.contains("do JavaScript") {
                // The JavaScript text is not AppleScript: check the reference it runs in, then stop reading.
                if let range = line.range(of: " in ", options: .backwards), let index = try windowIndex(in: String(line[range.upperBound...])) {
                    if let tab = Self.int(after: "tab ", in: String(line[range.upperBound...])), tab > order[index].tabs.count {
                        throw Self.invalidIndex("tab \(tab)")
                    }
                }
                return javaScriptResult
            }
            if line.hasPrefix("if "), line.hasSuffix(" then") {
                let holds = try condition(String(line.dropFirst(3).dropLast(5)))
                if !holds { skipping = true }
                continue
            }
            if line.hasPrefix("if "), let then = line.range(of: " then ") {
                if try condition(String(line[line.index(line.startIndex, offsetBy: 3)..<then.lowerBound])) {
                    try execute(String(line[then.upperBound...]))
                }
                continue
            }
            try execute(line)
        }
        return result
    }
}
