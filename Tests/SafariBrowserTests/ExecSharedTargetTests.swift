import Foundation
import XCTest
@testable import SafariBrowser

/// #170: the daemon's in-process exec dispatcher rebuilt and re-resolved the
/// script's shared target for every step — for a `--url` target, one full
/// window/tab enumeration per step. One exec run now resolves the shared
/// target once; a step with its own target flags still resolves its own, and
/// nothing is carried across exec requests.
final class ExecSharedTargetTests: XCTestCase, @unchecked Sendable {
    /// Minimal fake Safari: 2 windows, 3 tabs each; every AppleScript counted.
    /// Tabs are positional, so a test can navigate or close one mid-run.
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        private var windows = [(1...3).map { "https://w1.example/\($0)" }, (1...3).map { "https://w2.example/\($0)" }]
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        var enumerations: Int { scripts.filter { $0.contains("set windowCount to count of windows") }.count }
        var verifications: Int { scripts.filter { $0.contains("SB_TARGET_CHANGED") && $0.contains("return \"ok\"") }.count }
        func navigate(window: Int, tab: Int, to url: String) { lock.withLock { windows[window - 1][tab - 1] = url } }
        func close(window: Int, tab: Int) { lock.withLock { _ = windows[window - 1].remove(at: tab - 1) } }

        func respond(_ script: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            sent.append(script)
            if script.contains("set windowCount to count of windows") {
                let gs = "\u{1D}", rs = "\u{1E}"
                var out = ""
                for (i, tabs) in windows.enumerated() {
                    for (j, url) in tabs.enumerated() {
                        out += ["\(i + 1)", "\(j + 1)", j == 0 ? "1" : "0", url,
                                "Tab \(j + 1)", "個人 — Tab 1", "\(101 + i)"].joined(separator: gs) + rs
                    }
                }
                return out
            }
            guard let tab = Self.int(after: "tab ", in: script), let id = Self.int(after: "window id ", in: script) else {
                return "ok"
            }
            let tabs = windows.indices.contains(id - 101) ? windows[id - 101] : []
            guard tabs.indices.contains(tab - 1) else {
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get tab. Invalid index. (-1719)")
            }
            let url = tabs[tab - 1]
            if let pattern = Self.quoted(after: "does not contain ", in: script), !url.contains(pattern) {
                throw SafariBrowserError.appleScriptFailed("execution error: SB_TARGET_CHANGED (9001)")
            }
            if script.contains("return \"ok\"") { return "ok" }
            if script.contains("URL of") { return url }
            return "ok"
        }

        private static func int(after prefix: String, in text: String) -> Int? {
            guard let r = text.range(of: prefix) else { return nil }
            return Int(text[r.upperBound...].prefix(while: \.isNumber))
        }
        private static func quoted(after prefix: String, in text: String) -> String? {
            guard let r = text.range(of: prefix + "\"") else { return nil }
            return String(text[r.upperBound...].prefix(while: { $0 != "\"" }))
        }
    }

    private func dispatchAll(_ calls: [(cmd: String, args: [String])], shared: [String],
                             on fake: Fake, dispatcher: InProcessStepDispatcher = InProcessStepDispatcher()) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                for call in calls {
                    _ = try await dispatcher.dispatch(cmd: call.cmd, args: call.args, sharedTargetArgs: shared)
                }
            }
        }
    }

    func testSharedURLTargetIsResolvedOncePerExecRun() async throws {
        let fake = Fake()
        let steps: [(String, [String])] = [("get url", []), ("get title", []), ("js", ["1+1"]), ("get url", []), ("js", ["2+2"])]
        try await dispatchAll(steps, shared: ["--url", "w1.example/2"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, "five steps, one resolution of the shared target")
    }

    // MARK: - Verify R1: the cache is a hint, verified before every use

    private func run(_ steps: [(cmd: String, args: [String])], shared: [String], on fake: Fake,
                     between: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> [String] {
        let dispatcher = InProcessStepDispatcher()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                var out: [String] = []
                for (i, step) in steps.enumerated() {
                    between(i)
                    out.append(try await dispatcher.dispatch(cmd: step.cmd, args: step.args, sharedTargetArgs: shared))
                }
                return out
            }
        }
    }

    func testEveryStepThatReusesTheSharedTargetVerifiesItFirst() async throws {
        let fake = Fake()
        _ = try await run([("get url", []), ("get title", []), ("js", ["1+1"])], shared: ["--url", "w1.example/2"], on: fake)
        XCTAssertEqual(fake.enumerations, 1)
        XCTAssertEqual(fake.verifications, 2, "steps 2 and 3 check the cached tab before using it")
    }

    func testAfterTheTargetNavigatesAwayAStepFailsLikeStatelessExec() async throws {
        // Verify R1: a get step read the cached tab with no guard, so after a
        // navigation it returned the new page's URL, where stateless exec (one
        // fresh resolution per step) reports that nothing matches.
        let fake = Fake()
        do {
            _ = try await run([("get url", []), ("get url", [])], shared: ["--url", "w1.example/2"], on: fake) { i in
                if i == 1 { fake.navigate(window: 1, tab: 2, to: "https://other.example/x") }
            }
            XCTFail("the shared target no longer matches anything")
        } catch SafariBrowserError.documentNotFound {
            XCTAssertEqual(fake.enumerations, 2, "a failed check falls back to a fresh resolution")
        }
    }

    func testATargetThatMovedIsFoundAgain() async throws {
        let fake = Fake()
        let urls = try await run([("get url", []), ("get url", [])], shared: ["--url", "w1.example/2"], on: fake) { i in
            if i == 1 { fake.close(window: 1, tab: 1) }        // tab 2 is now tab 1
        }
        XCTAssertEqual(urls, ["https://w1.example/2", "https://w1.example/2"])
        XCTAssertEqual(fake.enumerations, 2)
    }

    func testADocumentIndexTargetIsNotCached() async throws {
        // `--document N` names a position with no URL to verify by; stateless
        // exec re-resolves it every step, so the daemon path does too.
        let fake = Fake()
        _ = try await run([("get url", []), ("get url", []), ("get url", [])], shared: ["--document", "2"], on: fake)
        XCTAssertEqual(fake.enumerations, 3)
        XCTAssertEqual(fake.verifications, 0)
    }

    func testAStepWithItsOwnTargetResolvesItsOwn() async throws {
        let fake = Fake()
        let steps: [(String, [String])] = [("get url", []), ("get url", ["--url", "w2.example/3"]), ("get url", [])]
        try await dispatchAll(steps, shared: ["--url", "w1.example/2"], on: fake)
        XCTAssertEqual(fake.enumerations, 2, "the shared target once, the override once")
    }

    func testNothingIsCarriedAcrossExecRequests() async throws {
        let fake = Fake()
        try await dispatchAll([("get url", [])], shared: ["--url", "w1.example/2"], on: fake)
        try await dispatchAll([("get url", [])], shared: ["--url", "w1.example/2"], on: fake)
        XCTAssertEqual(fake.enumerations, 2, "each exec request resolves afresh — no cross-request Safari state")
    }

    func testProfileFilterReachesTheSharedResolution() async throws {
        // --profile was parsed but never handed to the bridge on this path.
        let fake = Fake()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    _ = try await InProcessStepDispatcher().dispatch(
                        cmd: "get url", args: [], sharedTargetArgs: ["--url", "w1.example/2", "--profile", "nobody"])
                }
            }
            XCTFail("no window belongs to profile 'nobody'; the filter must reject the match")
        } catch SafariBrowserError.documentNotFound {
            // expected
        }
    }
}
