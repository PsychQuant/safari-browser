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
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        var enumerations: Int { scripts.filter { $0.contains("set windowCount to count of windows") }.count }
        func respond(_ script: String) -> String {
            lock.lock(); sent.append(script); lock.unlock()
            if script.contains("set windowCount to count of windows") {
                let gs = "\u{1D}", rs = "\u{1E}"
                var out = ""
                for w in 1...2 {
                    for t in 1...3 {
                        out += ["\(w)", "\(t)", t == 1 ? "1" : "0", "https://w\(w).example/\(t)",
                                "Tab \(t)", "個人 — Tab 1", "\(100 + w)"].joined(separator: gs) + rs
                    }
                }
                return out
            }
            if script.contains("URL of") { return "https://w1.example/2" }
            return "ok"
        }
    }

    private func dispatchAll(_ calls: [(cmd: String, args: [String])], shared: [String],
                             on fake: Fake, dispatcher: InProcessStepDispatcher = InProcessStepDispatcher()) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ fake.respond($0) }) {
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
                try await DaemonRequestContext.$appleScriptRunner.withValue({ fake.respond($0) }) {
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
