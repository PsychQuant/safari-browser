import Foundation
import XCTest
@testable import SafariBrowser

/// A fake Safari for #362. Windows are listed in z-order: the first is Safari window 1. A window named in
/// `closesOnRead` is open until the first script reads its tab count, and gone from then on.
final class FakeSafari: @unchecked Sendable {
    typealias Window = (id: Int, profile: String, tabs: [String])
    static let workIsTwoAndThree: [Window] = [
        (101, "Home", ["https://home.example/1"]),
        (303, "Work", ["https://work.example/a1", "https://work.example/a2"]),
        (404, "Work", ["https://work.example/b1"]),
    ]

    private let lock = NSLock()
    private let all: [Window]
    private var closed: Set<Int> = []
    private var listingCount = 0
    var closesOnRead: Int?
    var listingError: Error?
    /// The first listing that `listingError` fails (1 = every listing), so a resolver's own enumeration can succeed.
    var listingErrorFrom = 1
    /// A window that closes once the listing numbered `after` has been answered: the resolver sees it, the read and
    /// every later listing do not.
    var closesAfterListing: (id: Int, after: Int)?
    var readError: Error?

    init(windows: [Window]) { all = windows }

    var listings: Int { lock.withLock { listingCount } }
    private var open: [Window] { lock.withLock { all.filter { !closed.contains($0.id) } } }

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

    private static func notFound(_ what: String) -> SafariBrowserError {
        .appleScriptFailed("execution error: Can’t get \(what). (-1728)")
    }

    func respond(_ script: String) throws -> String {
        if script.contains("set windowCount to count of windows") {
            let n = lock.withLock { listingCount += 1; return listingCount }
            if let listingError, n >= listingErrorFrom { throw listingError }
            let out = FakeEnumeration.sourceForm(open.map {
                .titledTabs(id: $0.id, profile: $0.profile, urls: $0.tabs)
            })
            if let closing = closesAfterListing, n == closing.after { lock.withLock { _ = closed.insert(closing.id) } }
            return out
        }
        if let n = WindowIDCommandTests.TwoProfileFake.int(after: "get id of window ", in: script) {
            guard n >= 1, n <= open.count else { throw SafariBrowserError.appleScriptFailed("execution error: Invalid index. (-1719)") }
            return "\(open[n - 1].id)"
        }
        if script.contains("count of tabs of front window") {
            return open.first.map { "\($0.tabs.count)" } ?? "0"
        }
        if let id = WindowIDCommandTests.TwoProfileFake.int(after: "count of tabs of window id ", in: script) {
            if id == closesOnRead { lock.withLock { _ = closed.insert(id) } }
            if let readError { throw readError }
            guard let window = open.first(where: { $0.id == id }) else {
                // `readTabs` answers "0" when no window is open at all.
                if open.isEmpty { return "0" }
                throw Self.notFound("window id \(id)")
            }
            return "\(window.tabs.count)"
        }
        if let n = WindowIDCommandTests.TwoProfileFake.int(after: "count of tabs of window ", in: script) {
            if let readError { throw readError }
            guard n >= 1, n <= open.count else {
                if open.isEmpty { return "0" }
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get window \(n). Invalid index. (-1719)")
            }
            return "\(open[n - 1].tabs.count)"
        }
        if let id = WindowIDCommandTests.TwoProfileFake.int(after: "window id ", in: script) {
            guard let window = open.first(where: { $0.id == id }) else { throw Self.notFound("window id \(id)") }
            let tab = WindowIDCommandTests.TwoProfileFake.int(after: "tab ", in: script) ?? 1
            guard tab >= 1, tab <= window.tabs.count else { throw Self.notFound("tab \(tab)") }
            return script.contains("get URL of") ? window.tabs[tab - 1] : "Tab \(tab)"
        }
        if let n = WindowIDCommandTests.TwoProfileFake.int(after: "of window ", in: script) {
            guard n >= 1, n <= open.count else {
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get window \(n). Invalid index. (-1719)")
            }
            return "Tab 1"
        }
        return ""
    }
}
