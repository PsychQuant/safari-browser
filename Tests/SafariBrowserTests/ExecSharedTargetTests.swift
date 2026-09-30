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
            // The three guard forms `urlGuardClause` writes (#79); a regex
            // target has none and is checked in Swift from the URL read.
            let rejected: Bool
            if let p = Self.quoted(after: "does not contain ", in: script) { rejected = !url.contains(p) }
            else if let p = Self.quoted(after: "is not equal to ", in: script) { rejected = url != p }
            else if let p = Self.quoted(after: "does not end with ", in: script) { rejected = !url.hasSuffix(p) }
            else { rejected = false }
            if rejected {
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

    func testAfterTheTargetNavigatesAwayAStepReportsWhatAFreshResolutionReports() async throws {
        // Verify R1: a get step read the cached tab with no guard, so after a
        // navigation it returned the new page's URL, where a subprocess step
        // (its own fresh resolution) reports that nothing matches.
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

    func testAClosedWindowOnTheDaemonPathReportsNotFoundAndDoesNotPoisonTheCache() async throws {
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
                var messages: [String] = []
                for (cmd, args) in [("click", ["button"]), ("js", [String]())] {
                    do {
                        _ = try await dispatcher.dispatch(cmd: cmd, args: args, sharedTargetArgs: ["--url", "w1.example/2"])
                        XCTFail("\(cmd) \(args) must not run in-process")
                    } catch let error as ScriptDispatchError { messages.append(error.message) }
                }
                // The text a client sees is unchanged from before the check moved ahead of resolution.
                XCTAssertEqual(messages, ["command 'click' is not yet available in exec scripts",
                                          ScriptDispatchError.unsupportedArguments("js").message])
                XCTAssertTrue(messages[1].hasPrefix("step 'js' has arguments"), messages[1])
            }
        }
        XCTAssertEqual(fake.enumerations, 0, "an unsupported or malformed step must not pay for a resolution")
    }

    @MainActor  // NSAppleScript is created and compiled on the main actor (#130)
    func testTheVerificationScriptCompilesWithAHostilePattern() async throws {
        // The pattern reaches AppleScript as a string literal. The compile check
        // only proves the payload cannot break out of it (a raw line break is
        // legal inside a literal, so it cannot see a missing control-character
        // escape); the exact expected text below is written out by hand so the
        // escaping is not compared with itself.
        final class Captured: @unchecked Sendable { var script = "" }
        let captured = Captured()
        let hostile = "a\"b\\c\nd\re\tf 日本語 é 😀\" & (do shell script \"echo pwned\") & \""
        let ok = try await DaemonRequestContext.$appleScriptRunner.withValue({ captured.script = $0; return "ok" }) {
            try await SafariBridge.verifyResolvedTab(.resolvedTab(windowID: 101, tabInWindow: 1,
                                                                  rematch: .contains(hostile), profile: nil))
        }
        XCTAssertTrue(ok)
        let expected = "does not contain \"a\\\"b\\\\c\\nd\\re\\tf 日本語 é 😀\\\" & (do shell script \\\"echo pwned\\\") & \\\"\""
        XCTAssertTrue(captured.script.contains(expected), "expected \(expected) in:\n\(captured.script)")
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
        // `--document N` names a position with no URL to verify by; every
        // subprocess step re-resolves it, so the daemon path does too.
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


    // MARK: - Verify R3: every matcher form, the reset, cancellation, documents --profile

    private static let matcherForms: [[String]] = [
        ["--url-exact", "https://w1.example/2"], ["--url-endswith", "w1.example/2"],
        ["--url-regex", "^https://w1\\.example/2$"],
    ]

    func testEveryURLMatcherFormIsReusedWhileItStillMatches() async throws {
        for shared in Self.matcherForms {
            let fake = Fake()
            let urls = try await run([("get url", []), ("get url", []), ("get url", [])], shared: shared, on: fake)
            XCTAssertEqual(urls, Array(repeating: "https://w1.example/2", count: 3), "\(shared)")
            XCTAssertEqual(fake.enumerations, 1, "\(shared): one resolution, then checked reuse")
        }
    }

    func testEveryURLMatcherFormIsResolvedAfreshOnceItStopsMatching() async throws {
        // A get step has no guard of its own; the check before reuse is its
        // only protection, for the regex form too (checked in Swift).
        for shared in Self.matcherForms {
            let fake = Fake()
            do {
                _ = try await run([("get url", []), ("get url", [])], shared: shared, on: fake) { i in
                    if i == 1 { fake.navigate(window: 1, tab: 2, to: "https://other.example/x") }
                }
                XCTFail("\(shared): nothing matches after the navigation")
            } catch SafariBrowserError.documentNotFound {
                XCTAssertEqual(fake.enumerations, 2, "\(shared)")
            }
        }
    }

    func testAfterAFailedResolutionAnAmbiguousMatchIsReportedNotHidden() async throws {
        // The resolved tab navigates away (step 2 finds nothing), then comes
        // back while a second tab also matches. A subprocess step reports the
        // ambiguity at step 3; the daemon path must not reuse the old tab.
        let fake = Fake()
        fake.navigate(window: 1, tab: 2, to: "https://target.example/a")
        let dispatcher = InProcessStepDispatcher()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let shared = ["--url", "target.example"]
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                _ = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                fake.navigate(window: 1, tab: 2, to: "https://other.example/x")
                do {
                    _ = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                    XCTFail("nothing matches while the tab is away")
                } catch SafariBrowserError.documentNotFound {}
                fake.navigate(window: 1, tab: 2, to: "https://target.example/a")
                fake.navigate(window: 2, tab: 3, to: "https://target.example/b")
                do {
                    let url = try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared)
                    XCTFail("two tabs match; read \(url) instead of failing closed")
                } catch SafariBrowserError.ambiguousWindowMatch {}
            }
        }
    }

    func testAFailedResolutionLeavesNothingToReuse() async throws {
        final class Counts: @unchecked Sendable { var checks = 0; var resolutions = 0 }
        struct Gone: Error {}
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let args = ["--url", "x"]
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        _ = try await resolution.resolve(args: args, verify: { _ in counts.checks += 1; return true }) {
            counts.resolutions += 1; return tab
        }
        do {
            _ = try await resolution.resolve(args: args, verify: { _ in counts.checks += 1; return false }) {
                counts.resolutions += 1; throw Gone()
            }
            XCTFail("the fresh resolution failed")
        } catch is Gone {}
        _ = try await resolution.resolve(args: args, verify: { _ in counts.checks += 1; return true }) {
            counts.resolutions += 1; return tab
        }
        XCTAssertEqual(counts.checks, 1, "after a failed resolution there is nothing cached to check")
        XCTAssertEqual(counts.resolutions, 3)
    }

    func testACancelledCheckIsNotTakenForAFailedOne() async throws {
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let args = ["--url", "x"]
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        _ = try await resolution.resolve(args: args, verify: { _ in true }) { counts.resolutions += 1; return tab }
        do {
            _ = try await resolution.resolve(args: args, verify: { _ in throw CancellationError() }) {
                counts.resolutions += 1; return tab
            }
            XCTFail("cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(counts.resolutions, 1, "a cancelled step must not start a fresh resolution")
    }

    func testADocumentsStepHonoursTheProfileFilter() async throws {
        // `documents --profile X` lists only X's tabs; the daemon
        // exec step listed every profile.
        let fake = Fake()
        let rows = { (shared: [String]) -> Int in
            // No live AX scan in a unit test: the listing is what is under test.
            let out = try await WindowDialogObservation.$provider.withValue({ .unavailable(reason: "disabled") }) {
                try await self.run([("documents", [])], shared: shared, on: fake)[0]
            }
            let array = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Any]
            return array?.count ?? -1
        }
        let all = try await rows([])
        let mine = try await rows(["--profile", "個人"])
        let nobody = try await rows(["--profile", "nobody"])
        XCTAssertEqual(all, 6)
        XCTAssertEqual(mine, 6)
        XCTAssertEqual(nobody, 0)
    }


    // MARK: - Verify R4: case, first-match, profile, and the forms with nothing to check by

    func testTheVerificationScriptComparesCaseSensitively() async throws {
        // AppleScript compares strings case-insensitively unless told otherwise,
        // while the matcher the target was resolved with is case-sensitive.
        // The fake cannot show this, so the shipped script text is pinned.
        let matchers: [SafariBridge.UrlMatcher] = [.contains("Foo"), .exact("https://x.example/Foo"), .endsWith("Foo")]
        for matcher in matchers {
            final class Captured: @unchecked Sendable { var script = "" }
            let captured = Captured()
            _ = try await DaemonRequestContext.$appleScriptRunner.withValue({ captured.script = $0; return "ok" }) {
                try await SafariBridge.verifyResolvedTab(.resolvedTab(windowID: 101, tabInWindow: 1, rematch: matcher, profile: nil))
            }
            let script = captured.script
            let considering = try XCTUnwrap(script.range(of: "considering case"), script)
            let comparison = try XCTUnwrap(script.range(of: "(URL of _t)"), script)
            let end = try XCTUnwrap(script.range(of: "end considering"), script)
            XCTAssertTrue(considering.lowerBound < comparison.lowerBound && comparison.lowerBound < end.lowerBound,
                          "\(matcher): the comparison must sit inside `considering case`:\n\(script)")
        }
    }

    func testFirstMatchIsDecidedAtTheSharedResolutionAndReused() async throws {
        // Every fake tab matches "example"; `--first-match` picks the first in
        // window and tab order, once, and later steps reuse it after the check.
        let fake = Fake()
        let urls = try await run([("get url", []), ("get url", []), ("get url", [])],
                                 shared: ["--url", "example", "--first-match"], on: fake)
        XCTAssertEqual(urls, Array(repeating: "https://w1.example/1", count: 3))
        XCTAssertEqual(fake.enumerations, 1)
        XCTAssertEqual(fake.verifications, 2)
    }

    func testWithoutFirstMatchTheSameAmbiguousTargetIsRejected() async {
        let fake = Fake()
        do {
            _ = try await run([("get url", [])], shared: ["--url", "example"], on: fake)
            XCTFail("six tabs match")
        } catch SafariBrowserError.ambiguousWindowMatch {
        } catch {
            XCTFail("expected ambiguousWindowMatch, got \(error)")
        }
    }

    func testAURLTargetWithAProfileIsStillReused() async throws {
        let fake = Fake()
        let urls = try await run([("get url", []), ("get url", []), ("get url", [])],
                                 shared: ["--url", "w1.example/2", "--profile", "個人"], on: fake)
        XCTAssertEqual(urls, Array(repeating: "https://w1.example/2", count: 3))
        XCTAssertEqual(fake.enumerations, 1)
        XCTAssertEqual(fake.verifications, 2)
    }

    func testNoCheckIsMadeForTargetFormsWithNothingToCheckBy() async {
        // `--document`, `--tab`, `--window`, `--window --tab-in-window`,
        // `--profile` alone and no flag name no URL, so there is nothing a
        // check could confirm: none of them issues the guard script. Whether a
        // step succeeds against the fake is not the point, so errors are ignored.
        let forms: [[String]] = [["--document", "2"], ["--tab", "2"], ["--window", "1"],
                                 ["--window", "1", "--tab-in-window", "2"], ["--profile", "個人"], []]
        for shared in forms {
            let fake = Fake()
            let dispatcher = InProcessStepDispatcher()
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            await DaemonRequestContext.$current.withValue(context) {
                await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    for _ in 1...3 { _ = try? await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: shared) }
                }
            }
            XCTAssertEqual(fake.verifications, 0, "\(shared): no check before reuse")
            if shared.first == "--document" || shared.first == "--tab" || shared == ["--profile", "個人"] {
                XCTAssertEqual(fake.enumerations, 3, "\(shared): resolved afresh for each of the 3 steps")
            }
        }
    }


    // MARK: - Verify R5: real comparison semantics, step-level profile, mark-tab

    /// Run the guard clause `verifyResolvedTab` builds in real AppleScript, on a
    /// synthetic record with a `URL` property (no Safari is involved), and say
    /// whether it tripped. Bounded by a timeout, like the repo's other
    /// osascript tests.
    private func guardTrips(_ matcher: SafariBridge.UrlMatcher, url: String) async throws -> Bool {
        let clause = try XCTUnwrap(SafariBridge.urlGuardClause(for: matcher))
        let script = "set _t to {URL:\"\(url.escapedForAppleScript)\"}\n\(clause)\nreturn \"ok\""
        do {
            let out = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", script], timeout: 10)
            XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            return false
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertTrue(message.contains("SB_TARGET_CHANGED"), "neither ok nor the guard's own error:\n\(message)")
            return true
        }
    }

    func testTheGuardClauseComparesCaseSensitivelyInRealAppleScript() async throws {
        // Runners without osascript skip rather than fail or hang.
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"),
                          "osascript not available")
        // AppleScript compares strings case-insensitively unless told otherwise,
        // and the matcher the target was resolved with is case-sensitive. The
        // fake cannot show the difference; `osascript` can.
        let cases: [(SafariBridge.UrlMatcher, same: String, other: String)] = [
            (.contains("Foo"), "https://x.example/Foo", "https://x.example/foo"),
            (.exact("https://x.example/Foo"), "https://x.example/Foo", "https://x.example/foo"),
            (.endsWith("Foo"), "https://x.example/Foo", "https://x.example/foo"),
            (.contains("日本語é"), "https://x.example/日本語é", "https://x.example/日本語É"),
        ]
        for (matcher, same, other) in cases {
            let sameTrips = try await guardTrips(matcher, url: same)
            let otherTrips = try await guardTrips(matcher, url: other)
            XCTAssertFalse(sameTrips, "\(matcher): the same text must pass")
            XCTAssertTrue(otherTrips, "\(matcher): a different case must trip the guard")
        }
    }

    func testAStepsOwnProfileRestrictsItsResolution() async throws {
        // A step that carries its own `--profile` was parsed and dropped before.
        let fake = Fake()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                let dispatcher = InProcessStepDispatcher()
                let own = try await dispatcher.dispatch(
                    cmd: "get url", args: ["--url", "w1.example/2", "--profile", "個人"], sharedTargetArgs: [])
                XCTAssertEqual(own, "https://w1.example/2")
                do {
                    _ = try await dispatcher.dispatch(
                        cmd: "get url", args: ["--url", "w1.example/2", "--profile", "nobody"], sharedTargetArgs: [])
                    XCTFail("no window belongs to profile 'nobody'")
                } catch SafariBrowserError.documentNotFound {}
            }
        }
    }

    func testADocumentsStepWithItsOwnProfileListsOnlyThatProfile() async throws {
        let fake = Fake()
        let count = { (args: [String]) async throws -> Int in
            let out = try await WindowDialogObservation.$provider.withValue({ .unavailable(reason: "disabled") }) {
                try await self.run([("documents", args)], shared: [], on: fake)[0]
            }
            return (try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Any])?.count ?? -1
        }
        let mine = try await count(["--profile", "個人"])
        let nobody = try await count(["--profile", "nobody"])
        XCTAssertEqual(mine, 6)
        XCTAssertEqual(nobody, 0)
    }

    func testTheTabMarkerRespectsTheExecLevelProfile() async {
        // `--mark-tab` wraps the whole run and reads and rewrites the target's
        // title before the first step. It resolved the target without the
        // profile, so it could mark a tab of another profile.
        let fake = Fake()
        let envelope = try! JSONSerialization.data(withJSONObject: [
            "steps": [], "targetArgs": ["--url", "w1.example/2", "--profile", "nobody"], "markTab": "ephemeral",
        ])
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await DaemonDispatch.Handlers.execRunScript(paramsData: envelope)
                }
            }
            XCTFail("no window belongs to profile 'nobody'")
        } catch SafariBrowserError.documentNotFound {
        } catch {
            XCTFail("expected documentNotFound, got \(error)")
        }
        XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, "no title may be read or written:\n\(fake.scripts.joined(separator: "\n---\n"))")
    }


    // MARK: - Verify R6: what reuse means for the position, cancellation, forms that must succeed

    func testASecondMatchingTabDoesNotStopTheResolvedPositionBeingUsed() async throws {
        // The daemon path resolved exactly one tab; a second tab starts matching
        // before step 2 while the first still does. The position is reused with
        // no further enumeration and no ambiguity error, where a subprocess step
        // would resolve afresh and report the ambiguity (the spec says so).
        let fake = Fake()
        fake.navigate(window: 1, tab: 2, to: "https://target.example/a")
        let urls = try await run([("get url", []), ("get url", [])], shared: ["--url", "target.example"], on: fake) { i in
            if i == 1 { fake.navigate(window: 2, tab: 3, to: "https://target.example/b") }
        }
        XCTAssertEqual(urls, ["https://target.example/a", "https://target.example/a"])
        XCTAssertEqual(fake.enumerations, 1)
    }

    func testTheResolvedPositionIsUsedEvenWhenItNowHoldsAnotherMatchingTab() async throws {
        // The consequence the spec states: with no stable tab id, a tab to the
        // left closing shifts the resolved tab and another matching tab takes its
        // position. The URL check still passes, so the step reads that tab.
        let fake = Fake()
        fake.navigate(window: 1, tab: 2, to: "https://target.example/a")
        let urls = try await run([("get url", []), ("get url", [])], shared: ["--url", "target.example"], on: fake) { i in
            if i == 1 {
                fake.close(window: 1, tab: 1)                                        // target/a is now tab 1
                fake.navigate(window: 1, tab: 2, to: "https://target.example/b")     // tab 2 now matches too
            }
        }
        XCTAssertEqual(urls, ["https://target.example/a", "https://target.example/b"])
        XCTAssertEqual(fake.enumerations, 1)
    }

    func testTheFormsThatCanRunHereSucceedWithoutACheck() async throws {
        // The forms whose steps the fake can answer with a URL carry a success
        // assertion; `testNoCheckIsMadeForTargetFormsWithNothingToCheckBy` ignores
        // errors and covers the rest (the fake answers a bare `--profile` read with
        // a generic "ok", so only its enumeration count is asserted there).
        for shared in [["--document", "2"], ["--tab", "2"]] {
            let fake = Fake()
            let urls = try await run([("get url", []), ("get url", []), ("get url", [])], shared: shared, on: fake)
            XCTAssertEqual(urls.count, 3, "\(shared)")
            XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("https://") }, "\(shared): \(urls)")
            XCTAssertEqual(fake.verifications, 0, "\(shared)")
            XCTAssertEqual(fake.enumerations, 3, "\(shared): resolved for each of the 3 steps")
        }
    }

    func testACancelledRequestDoesNotStartAResolutionWhateverTheCheckRaised() async {
        // Only CancellationError was recognised; any error raised while the task
        // is cancelled must also end in cancellation, never in a fresh resolution.
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        struct Odd: Error {}
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let args = ["--url", "x"]
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        _ = try? await resolution.resolve(args: args, verify: { _ in true }) { counts.resolutions += 1; return tab }
        let task = Task {
            try await resolution.resolve(args: args, verify: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw Odd()
            }) { counts.resolutions += 1; return tab }
        }
        do {
            _ = try await task.value
            XCTFail("the request was cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(counts.resolutions, 1, "a cancelled request must not resolve afresh")
    }


    func testACheckThatReturnsAfterCancellationStartsNothing() async {
        // Cancellation is cooperative: a check can cancel the task and still
        // return normally. Neither answer may lead to a resolution or a
        // dispatchable target.
        for verdict in [false, true] {
            final class Counts: @unchecked Sendable { var resolutions = 0 }
            let counts = Counts()
            let resolution = InProcessStepDispatcher.SharedTargetResolution()
            let args = ["--url", "x"]
            let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
            _ = try? await resolution.resolve(args: args, verify: { _ in true }) { counts.resolutions += 1; return tab }
            let task = Task { () -> SafariBridge.TargetDocument in
                try await resolution.resolve(args: args, verify: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return verdict
                }) { counts.resolutions += 1; return tab }
            }
            do {
                _ = try await task.value
                XCTFail("verdict \(verdict): the request was cancelled, no target may be returned")
            } catch is CancellationError {
            } catch {
                XCTFail("verdict \(verdict): expected CancellationError, got \(error)")
            }
            XCTAssertEqual(counts.resolutions, 1, "verdict \(verdict): a cancelled request must not resolve afresh")
        }
    }

    func testAResolutionRequestedByACancelledTaskDoesNotRun() async {
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        let task = Task { () -> SafariBridge.TargetDocument in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolution.resolve(args: ["--url", "x"], verify: { _ in true }) { counts.resolutions += 1; return tab }
        }
        do {
            _ = try await task.value
            XCTFail("the task was cancelled before it asked")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(counts.resolutions, 0)
    }


    func testAResolutionThatFinishesAfterCancellationIsNotCachedOrReturned() async {
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let args = ["--url", "x"]
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        let task = Task { () -> SafariBridge.TargetDocument in
            try await resolution.resolve(args: args, verify: { _ in true }) {
                counts.resolutions += 1
                withUnsafeCurrentTask { $0?.cancel() }      // cancelled while it resolved
                return tab
            }
        }
        do {
            _ = try await task.value
            XCTFail("the request was cancelled while it resolved")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        // Nothing was cached: the next request-shaped call has to resolve afresh.
        let again = try? await resolution.resolve(args: args, verify: { _ in XCTFail("nothing cached to verify"); return true }) {
            counts.resolutions += 1; return tab
        }
        XCTAssertNotNil(again)
        XCTAssertEqual(counts.resolutions, 2)
    }
}
