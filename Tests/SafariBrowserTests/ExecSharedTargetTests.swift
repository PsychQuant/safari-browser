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
    /// Tabs are positional and windows keep their ids, so a test can navigate
    /// or close a tab, close a window, or open a new one mid-run.
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        private var windows: [(id: Int, tabs: [String])] = [
            (101, (1...3).map { "https://w1.example/\($0)" }), (102, (1...3).map { "https://w2.example/\($0)" }),
        ]
        /// #170 verify R2: the daemon runs scripts through NSAppleScript, whose
        /// error message carries no numeric code (-1719 / -1728) and a curly
        /// apostrophe. osascript's text, which every fake used, ends in "(-1719)".
        var daemonShapedErrors = false
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        var enumerations: Int { scripts.filter { $0.contains("set windowCount to count of windows") }.count }
        var verifications: Int { scripts.filter { $0.contains("SB_TARGET_CHANGED") && $0.contains("return \"ok\"") }.count }
        func navigate(window: Int, tab: Int, to url: String) {
            lock.withLock { if let i = windows.firstIndex(where: { $0.id == 100 + window }) { windows[i].tabs[tab - 1] = url } }
        }
        func close(window: Int, tab: Int) {
            lock.withLock { if let i = windows.firstIndex(where: { $0.id == 100 + window }) { windows[i].tabs.remove(at: tab - 1) } }
        }
        func closeWindow(id: Int) { lock.withLock { windows.removeAll { $0.id == id } } }
        func openWindow(id: Int, tabs: [String]) { lock.withLock { windows.append((id, tabs)) } }

        func respond(_ script: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            sent.append(script)
            if script.contains("set windowCount to count of windows") {
                let gs = "\u{1D}", rs = "\u{1E}"
                var out = ""
                for (i, window) in windows.enumerated() {
                    for (j, url) in window.tabs.enumerated() {
                        out += ["\(i + 1)", "\(j + 1)", j == 0 ? "1" : "0", url,
                                "Tab \(j + 1)", "個人 — Tab 1", "\(window.id)"].joined(separator: gs) + rs
                    }
                }
                return out
            }
            guard let tab = Self.int(after: "tab ", in: script), let id = Self.int(after: "window id ", in: script) else {
                return "ok"
            }
            guard let window = windows.first(where: { $0.id == id }) else {
                throw SafariBrowserError.appleScriptFailed(daemonShapedErrors
                    ? "Safari got an error: Can’t get window id \(id)."
                    : "execution error: Safari got an error: Can’t get window id \(id). (-1728)")
            }
            guard window.tabs.indices.contains(tab - 1) else {
                throw SafariBrowserError.appleScriptFailed(daemonShapedErrors
                    ? "Safari got an error: Can’t get tab \(tab) of window id \(id). Invalid index."
                    : "execution error: Can’t get tab. Invalid index. (-1719)")
            }
            let url = window.tabs[tab - 1]
            if let pattern = Self.quoted(after: "does not contain ", in: script), !url.contains(pattern) {
                throw SafariBrowserError.appleScriptFailed(daemonShapedErrors
                    ? "SB_TARGET_CHANGED" : "execution error: SB_TARGET_CHANGED (9001)")
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

    // MARK: - Verify R2: the daemon's error shape, and nothing resolved in vain

    func testAClosedTabOnTheDaemonPathIsResolvedAfresh() async throws {
        // Round 2: the daemon's NSAppleScript error has no -1719, so the check
        // threw instead of reporting "not verified", and the error escaped.
        let fake = Fake()
        fake.daemonShapedErrors = true
        let urls = try await run([("get url", []), ("get url", [])], shared: ["--url", "w1.example/3"], on: fake) { i in
            if i == 1 { fake.close(window: 1, tab: 1) }          // tab 3 no longer exists; the page is now tab 2
        }
        XCTAssertEqual(urls, ["https://w1.example/3", "https://w1.example/3"])
        XCTAssertEqual(fake.enumerations, 2)
    }

    func testAClosedWindowOnTheDaemonPathFailsLikeStatelessAndDoesNotPoisonTheCache() async throws {
        // A check that threw never cleared the cache, so every later step
        // failed too, even after the page reappeared in another window.
        let fake = Fake()
        fake.daemonShapedErrors = true
        let dispatcher = InProcessStepDispatcher()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                let shared = ["--url", "w2.example/2"]
                _ = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                fake.closeWindow(id: 102)
                do {
                    _ = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                    XCTFail("nothing matches after the window closed")
                } catch SafariBrowserError.documentNotFound {}
                fake.openWindow(id: 103, tabs: ["https://w2.example/2"])
                let again = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                XCTAssertEqual(again, "https://w2.example/2")
            }
        }
        XCTAssertEqual(fake.enumerations, 3)
    }

    func testAStepThatCannotRunDoesNotResolveTheTarget() async throws {
        let fake = Fake()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                let dispatcher = InProcessStepDispatcher()
                for (cmd, args) in [("click", ["button"]), ("js", [String]())] {
                    do {
                        _ = try await dispatcher.dispatch(cmd: cmd, args: args, sharedTargetArgs: ["--url", "w1.example/2"])
                        XCTFail("\(cmd) \(args) must not run in-process")
                    } catch is ScriptDispatchError {}
                }
            }
        }
        XCTAssertEqual(fake.enumerations, 0, "an unsupported or malformed step must not pay for a resolution")
    }

    func testTheVerificationScriptCompilesWithAHostilePattern() async throws {
        // The pattern reaches AppleScript as a string literal; quotes,
        // backslashes and line breaks must not end it early.
        final class Captured: @unchecked Sendable { var script = "" }
        let captured = Captured()
        let hostile = "a\"b\\c\nd\" & (do shell script \"echo pwned\") & \""
        let ok = try await DaemonRequestContext.$appleScriptRunner.withValue({ captured.script = $0; return "ok" }) {
            try await SafariBridge.verifyResolvedTab(.resolvedTab(windowID: 101, tabInWindow: 1,
                                                                  rematch: .contains(hostile), profile: nil))
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(captured.script.contains("does not contain \"\(hostile.escapedForAppleScript)\""), captured.script)
        let script = try XCTUnwrap(NSAppleScript(source: captured.script))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
        XCTAssertFalse(captured.script.contains("do shell script \"echo"), "the payload must stay inside the literal")
    }

    func testTheDaemonHandlerBuildsAFreshDispatcherPerRequest() async throws {
        // Pinned at the handler, not only at the dispatcher: one stored
        // dispatcher would carry a resolved window and tab across requests.
        let fake = Fake()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let envelope = try JSONSerialization.data(withJSONObject: [
            "steps": [["cmd": "get url"]], "targetArgs": ["--url", "w1.example/2"],
        ])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                _ = try await DaemonDispatch.Handlers.execRunScript(paramsData: envelope)
                _ = try await DaemonDispatch.Handlers.execRunScript(paramsData: envelope)
            }
        }
        XCTAssertEqual(fake.enumerations, 2)
        XCTAssertEqual(fake.verifications, 0, "the second request must not reuse the first request's target")
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
