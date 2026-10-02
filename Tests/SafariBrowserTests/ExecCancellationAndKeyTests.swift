import Foundation
import XCTest
@testable import SafariBrowser

/// #170 re-review: a cancelled `exec` request, and what the shared target and the compile cache are
/// keyed by. A cancelled request (the daemon cancels in-flight requests when it shuts down) must
/// not run a step with side effects, whichever way the step names its target.
final class ExecCancellationAndKeyTests: XCTestCase, @unchecked Sendable {
    typealias Fake = ExecSharedTargetTests.Fake

    // MARK: - The interpreter

    /// Records what it was asked to run, optionally cancelling the task or throwing while it does.
    private final class Recorder: StepDispatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var cancelDuring: Int?
        var throwCancellationAt: Int?
        var ran: [String] { lock.withLock { seen } }
        func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
            let index = lock.withLock { () -> Int in seen.append(cmd + " " + args.joined(separator: " ")); return seen.count - 1 }
            if cancelDuring == index { withUnsafeCurrentTask { $0?.cancel() } }
            if throwCancellationAt == index { throw CancellationError() }
            return "ok"
        }
    }

    private func steps(_ count: Int, onError: String = "continue") throws -> [ScriptStep] {
        let json = "[" + (0..<count).map { #"{"cmd":"get url","args":["s\#($0)"],"onError":"\#(onError)"}"# }.joined(separator: ",") + "]"
        return try ScriptInterpreter.parseScript(source: json, maxSteps: 100)
    }

    private func target() throws -> TargetOptions { try TargetOptions.parse([]) }

    func testARequestCancelledBeforeItStartsRunsNoStep() async throws {
        let recorder = Recorder()
        let parsed = try steps(3)
        let target = try target()
        let task = Task { () throws -> [StepResult] in
            while !Task.isCancelled { await Task.yield() }   // start only once cancelled, whatever the scheduling
            return try await ScriptInterpreter(dispatcher: recorder).runSteps(parsed, target: target)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return results")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
        XCTAssertEqual(recorder.ran, [], "no step ran for a cancelled request")
    }

    func testACancellationDuringAStepStopsTheRunWhateverOnErrorSays() async throws {
        for onError in ["continue", "abort"] {
            let recorder = Recorder()
            recorder.cancelDuring = 0
            let parsed = try steps(3, onError: onError)
            let target = try target()
            let task = Task { try await ScriptInterpreter(dispatcher: recorder).runSteps(parsed, target: target) }
            do {
                _ = try await task.value
                XCTFail("onError \(onError): the request was cancelled during step 0")
            } catch is CancellationError {
            } catch { XCTFail("onError \(onError): expected CancellationError, got \(error)") }
            XCTAssertEqual(recorder.ran.count, 1, "onError \(onError): nothing runs after the cancellation: \(recorder.ran)")
        }
    }

    /// A step that throws `CancellationError` is not a step error: it used to be recorded as
    /// `internalError` and, under `onError: continue`, followed by the next step.
    func testACancellationThrownByAStepIsNotRecordedAsAStepError() async throws {
        let recorder = Recorder()
        recorder.throwCancellationAt = 0
        do {
            _ = try await ScriptInterpreter(dispatcher: recorder).runSteps(try steps(3), target: try target())
            XCTFail("the cancellation must propagate, not become an internalError row")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
        XCTAssertEqual(recorder.ran.count, 1)
    }

    func testARunThatIsNotCancelledIsUnchanged() async throws {
        let recorder = Recorder()
        let results = try await ScriptInterpreter(dispatcher: recorder).runSteps(try steps(3), target: try target())
        XCTAssertEqual(results.map(\.status), [.ok, .ok, .ok])
        XCTAssertEqual(recorder.ran.count, 3)
    }

    // MARK: - The dispatcher

    private func inFake<T>(_ fake: Fake, _ body: () async throws -> T) async rethrows -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) { try await body() }
        }
    }

    /// A step that names its own target resolves outside the shared object. A cancelled request
    /// must not enumerate for it, and must not run the command after a resolver that finished late.
    func testAStepWithItsOwnTargetStartsNothingWhenCancelledAndRunsNothingAfterALateResolver() async throws {
        let dispatcher = InProcessStepDispatcher()
        // Cancelled before the step: no enumeration, no command.
        let early = Fake()
        let task = Task { () -> String in
            while !Task.isCancelled { await Task.yield() }   // start only once cancelled
            return try await self.inFake(early) {
                try await dispatcher.dispatch(cmd: "js", args: ["1+1", "--url", "w1.example/2"], sharedTargetArgs: [])
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(early.scripts, [], "nothing was sent for a cancelled request")

        // Cancelled while the resolver runs: the enumeration answers normally, and the command still must not follow.
        let late = Fake()
        let lateTask = Task { () -> String in
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            return try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    let answer = try late.respond(source)
                    if source.contains("set windowCount to count of windows") { withUnsafeCurrentTask { $0?.cancel() } }
                    return answer
                }) {
                    try await dispatcher.dispatch(cmd: "js", args: ["1+1", "--url", "w1.example/2"], sharedTargetArgs: [])
                }
            }
        }
        do { _ = try await lateTask.value; XCTFail("cancelled during resolution") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(late.enumerations, 1)
        XCTAssertFalse(late.scripts.contains { $0.contains("do JavaScript") }, "the command's AppleScript must not follow a cancellation:\n\(late.scripts.joined(separator: "\n---\n"))")
    }

    func testADocumentsStepStartsNothingWhenCancelled() async throws {
        let fake = Fake()
        let task = Task { () -> String in
            while !Task.isCancelled { await Task.yield() }   // start only once cancelled
            return try await self.inFake(fake) {
                try await InProcessStepDispatcher().dispatch(cmd: "documents", args: [], sharedTargetArgs: [])
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.scripts, [])
    }

    /// `documents` and a skipped step never trigger a resolution of the shared target, whatever the
    /// target is: the shared object is only asked by steps that read through it.
    func testADocumentsStepNeverEnumeratesForTheSharedTargetEvenForAURLTarget() async throws {
        let fake = Fake()
        _ = try await inFake(fake) {
            try await InProcessStepDispatcher().dispatch(cmd: "documents", args: [], sharedTargetArgs: ["--url", "w1.example/2"])
        }
        XCTAssertEqual(fake.verifications, 0, "no check of a shared target that was never resolved")
        // The listing is the one enumeration a documents step makes; no resolution of the URL target adds a second.
        XCTAssertEqual(fake.enumerations, 1)
    }

    /// The spec says a step skipped by `if:` never triggers a resolution. Run through the real
    /// interpreter and the in-process dispatcher with a URL target nobody shows: a resolution would
    /// enumerate, and would fail, whereas the skipped step and the `documents` step do neither.
    func testASkippedStepAndADocumentsStepTriggerNoResolutionOfTheSharedTarget() async throws {
        let fake = Fake()
        let parsed = try ScriptInterpreter.parseScript(source: """
            [{"cmd":"get url","if":"$missing exists"},{"cmd":"documents"}]
            """, maxSteps: 10)
        let target = try TargetOptions.parse(["--url", "no-such-tab.example"])
        let results = try await inFake(fake) {
            try await ScriptInterpreter(dispatcher: InProcessStepDispatcher()).runSteps(parsed, target: target)
        }
        XCTAssertEqual(results.map(\.status), [.skipped, .ok])
        XCTAssertEqual(fake.verifications, 0)
        XCTAssertEqual(fake.enumerations, 1, "only the listing the documents step makes, none for the shared target")
    }

    // MARK: - What the shared target is keyed by

    func testTheSharedTargetIsReusedOnlyForTheSameArguments() async throws {
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        func resolve(_ args: [String]) async throws { _ = try await resolution.resolve(args: args, verify: { _ in true }) { counts.resolutions += 1; return tab } }
        try await resolve(["--url", "a"])
        try await resolve(["--url", "a"])
        XCTAssertEqual(counts.resolutions, 1, "the same arguments reuse the resolution")
        try await resolve(["--url", "b"])
        XCTAssertEqual(counts.resolutions, 2, "other arguments resolve afresh")
        try await resolve(["--url", "b", "--first-match"])
        XCTAssertEqual(counts.resolutions, 3)
    }

    /// Swift's `==` treats canonically equivalent text as equal; the matcher and AppleScript do not.
    func testCanonicallyEquivalentButByteDifferentPatternsAreDifferentTargets() async throws {
        final class Counts: @unchecked Sendable { var resolutions = 0 }
        let counts = Counts()
        let resolution = InProcessStepDispatcher.SharedTargetResolution()
        let tab = SafariBridge.TargetDocument.resolvedTab(windowID: 101, tabInWindow: 2, rematch: .contains("x"), profile: nil)
        let nfc = "caf\u{00E9}", nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "the premise: Swift calls them equal")
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        _ = try await resolution.resolve(args: ["--url", nfc], verify: { _ in true }) { counts.resolutions += 1; return tab }
        _ = try await resolution.resolve(args: ["--url", nfd], verify: { _ in true }) { counts.resolutions += 1; return tab }
        XCTAssertEqual(counts.resolutions, 2, "a different spelling of the pattern is not served from the first one's resolution")
    }

    // MARK: - What the compile cache is keyed by

    /// The cache served one request's compiled script for another's when their sources differed only
    /// in Unicode normalisation (`String` equality), though NSAppleScript tells the two apart.
    func testTheCompileCacheKeepsNormalisationFormsApart() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let nfc = "return \"\u{30AC}\u{00E9}\""
        let nfd = "return \"\u{30AB}\u{3099}e\u{0301}\""
        XCTAssertEqual(nfc, nfd, "the premise: Swift calls them equal")
        let first = try await cache.execute(source: nfc).stringValue
        let second = try await cache.execute(source: nfd).stringValue
        let count = await cache.cacheCount
        XCTAssertEqual(count, 2, "two sources that differ in bytes are two entries")
        XCTAssertEqual(first?.unicodeScalars.count, 2)
        XCTAssertEqual(second?.unicodeScalars.count, 4, "the NFD source runs as itself, not as the NFC one that was compiled first")
        let hasNFC = await cache.contains(source: nfc)
        let hasNFD = await cache.contains(source: nfd)
        XCTAssertTrue(hasNFC && hasNFD)
    }

    func testTheCompileCacheKeepsAtLeastOneScript() async throws {
        let cache = PreCompiledScripts.CompileCache(capacity: 0)
        try await cache.compile(source: "return 1")
        try await cache.compile(source: "return 2")
        let count = await cache.cacheCount
        let hasSecond = await cache.contains(source: "return 2")
        XCTAssertEqual(count, 1, "a capacity below one is one, never an unbounded or empty cache")
        XCTAssertTrue(hasSecond)
    }
}
