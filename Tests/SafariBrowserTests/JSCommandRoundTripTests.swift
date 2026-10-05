import Foundation
import XCTest
@testable import SafariBrowser

/// #180 verify round 1: the fix that took `js` from six window enumerations
/// per command to at most one lived in a single call site
/// (`JSCommand.run` → `resolveToAnchoredTarget`), and nothing tested it —
/// reverting that line to `resolveToConcreteTarget` left the whole suite green,
/// and the live `e2e-target-identity.sh` only exercises `--url` targets, which
/// were already anchored before #180.
///
/// These tests run the real `JSCommand` against a fake Safari (every AppleScript
/// goes through `DaemonRequestContext.appleScriptRunner`) shaped like the
/// machine in the issue: 5 windows, 96 + 2 + 6 + 1 + 4 = 109 tabs. They count
/// what the command actually sends, so the bound holds at 109 tabs without
/// opening 109 real tabs.
final class JSCommandRoundTripTests: XCTestCase, @unchecked Sendable {

    // MARK: - Fake Safari

    /// Thread-safe record of every AppleScript the command sent.
    final class FakeSafari: @unchecked Sendable {
        let tabCounts: [Int]
        /// Window id of AppleScript window N is `idBase + N`.
        let idBase = 100
        /// When set, `do JavaScript` scripts containing this marker raise -1719,
        /// as Safari does when the addressed tab no longer exists.
        let failJSContaining: String?
        private let lock = NSLock()
        private var sent: [String] = []

        /// Seconds each enumeration takes — the issue's machine took 3–4 s,
        /// which is what let the dialog gate's 2 s cache expire mid-command.
        var enumerationDelay: TimeInterval = 0
        var javaScriptDelay: TimeInterval = 0
        /// #221: seconds a whole-window URL read takes (a poll of `wait --for-url`).
        var windowURLReadDelay: TimeInterval = 0
        /// #221: seconds the Nth whole-window URL read takes (index 0 is the first poll); later
        /// reads take `windowURLReadDelay`.
        var windowURLReadDelays: [TimeInterval] = []
        /// #221: raised by every whole-window URL read (a poll), after its delay.
        var windowURLReadError: Error?
        private var urlPolls = 0
        /// #221: what a `wait --js` poll answers (`"true"` makes the condition hold); empty otherwise.
        var waitJavaScriptAnswer = ""
        /// #221: seconds the Nth `wait --js` poll takes (index 0 is the first poll); polls past the
        /// end take `javaScriptDelay`.
        var waitPollDelays: [TimeInterval] = []
        /// #221: the condition holds from this poll on (1-based); nil leaves it to `waitJavaScriptAnswer`.
        var waitConditionHoldsFromPoll: Int?
        /// #221: raised by every `wait --js` poll, after its delay.
        var waitPollError: Error?
        private var waitPolls = 0
        private var cancelledDuringPoll = false
        /// #221: true when a poll (of either kind) noticed, after it had waited, that its task had been cancelled.
        var aPollWasCancelled: Bool { lock.withLock { cancelledDuringPoll } }
        var failWithTimeout = false
        /// #255: Safari swallows a SyntaxError and answers nothing for a wrapper that does not parse.
        var expressionFormParses = true
        var statementFormParses = true
        /// #255: what a wrapper that parsed answers (the reply `JSWrapper.parseInline` reads).
        var inlineAnswer = "SB1:OK:5:hello\u{1E}"
        /// #255: the URL the tab had before the code ran, read in the same AppleScript.
        var capturedURL = "https://w1.example/53"
        /// #255: when set, a plain read of tab 53's URL answers this (the code navigated the page).
        var navigatedURL: String?
        /// #255: with `navigatedURL` set, only reads from this one on (1-based) see it; earlier reads
        /// answer the unchanged URL. nil = every read sees it.
        var navigatesFromURLRead: Int?
        private var plainURLReads = 0
        /// #255: the first N wrapper dispatches raise the identity-guard sentinel, as Safari does when
        /// the guarded tab stopped matching; later ones answer normally (the bounded retry).
        var guardTripsOnFirstWrapperDispatches = 0
        private var wrapperDispatches = 0
        /// #255: answer an empty plain read of `window.__sbResult` (the chunked-read fallback).
        var storedPlainReadIsEmpty = false
        /// #255: enumerate in the legacy 6-field shape, without the window-id column; the resolved
        /// target then stays positional even with `--profile`.
        var legacyEnumeration = false

        init(tabCounts: [Int] = [96, 2, 6, 1, 4], failJSContaining: String? = nil) {
            self.tabCounts = tabCounts
            self.failJSContaining = failJSContaining
        }

        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        private var tab53HasNavigated: Bool { lock.lock(); defer { lock.unlock() }; return tab53Navigated }
        var enumerations: Int { scripts.filter { $0.contains("set windowCount to count of windows") }.count }
        /// `windowAnchorScript` only — the enumeration also reads
        /// `index of current tab of window w`, so match the anchor's own shape.
        var anchors: [String] { scripts.filter { $0.contains("index of current tab of window id _id") } }
        /// #255: the cheap `--window N --tab-in-window M` anchor (id + tab count), not an enumeration.
        var tabAnchors: [String] { scripts.filter { $0.contains("count of tabs of window id _id") } }
        /// When set, JavaScript steps carrying the current-tab guard fail the
        /// guard (the anchored tab is no longer the window's current tab).
        var tripGuard = false
        /// #168: after the first URL read of tab 53 of window 1, that tab has
        /// navigated to `https://w1.example/done` — in URL reads and in the
        /// enumeration alike.
        var navigateTab53AfterFirstURLRead = false
        private var tab53Navigated = false
        /// #168 verify R1: after the first whole-window URL read, tab 1 of
        /// window 1 closes, so every later tab of that window moves left.
        var closeWindow1Tab1AfterFirstWindowRead = false
        /// #168 verify R2: tab 1 of window 1 closes as soon as the resolving
        /// enumeration has read the window — before the first poll.
        var closeWindow1Tab1AfterEnumeration = false
        /// #168 verify R2: window 1 closes after the first whole-window URL
        /// read; later reads fail as Safari fails them (-1728).
        var closeWindow1AfterFirstWindowRead = false
        private var window1Closed = false
        private var window1Tab1Closed = false
        private var windowReads = 0
        var windowURLReads: [String] { scripts.filter { $0.contains("URL of every tab of window id ") } }
        var javaScripts: [String] { scripts.filter { $0.contains("do JavaScript") } }
        /// One line per script sent, for assertion messages.
        var transcript: String {
            scripts.enumerated().map { "[\($0.offset)] " + $0.element
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: "").prefix(140) }.joined(separator: "\n")
        }

        /// The 7-field GS/RS wire format of `listAllWindowsScript`.
        var enumeration: String {
            let gs = "\u{1D}", rs = "\u{1E}"
            var out = ""
            for (offset, count) in tabCounts.enumerated() {
                let w = offset + 1
                for t in 1...count {
                    let url = (w == 1 && t == 53 && tab53HasNavigated) ? "https://w1.example/done" : "https://w\(w).example/\(t)"
                    var fields = ["\(w)", "\(t)", t == 1 ? "1" : "0", url, "Tab \(t)", "個人 — Tab 1"]
                    if !legacyEnumeration { fields.append("\(idBase + w)") }
                    out += fields.joined(separator: gs) + rs
                }
            }
            return out
        }

        /// Current URLs of AppleScript window `w`, after any simulated change.
        private func urls(ofWindow w: Int) -> [String] {
            guard w >= 1, w <= tabCounts.count else { return [] }
            var list = (1...tabCounts[w - 1]).map { t in
                (w == 1 && t == 53 && tab53Navigated) ? "https://w1.example/done" : "https://w\(w).example/\(t)"
            }
            if w == 1 && window1Tab1Closed { list.removeFirst() }
            return list
        }

        func respond(_ script: String) throws -> String {
            lock.lock(); sent.append(script); lock.unlock()
            if tripGuard, script.contains("index of current tab of _w") {
                throw SafariBrowserError.appleScriptFailed(
                    "execution error: SB_TARGET_CHANGED: the anchored tab is no longer current (9001)")
            }
            if script.contains("URL of every tab of window id "),
               let id = Self.firstInt(after: "URL of every tab of window id ", in: script) {
                let number = lock.withLock { () -> Int in urlPolls += 1; return urlPolls }
                let delay = number <= windowURLReadDelays.count ? windowURLReadDelays[number - 1] : windowURLReadDelay
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                    if Task.isCancelled { lock.withLock { cancelledDuringPoll = true } }
                }
                if let windowURLReadError { throw windowURLReadError }
                lock.lock(); defer { lock.unlock() }
                windowReads += 1
                if window1Closed, id == idBase + 1 {
                    throw SafariBrowserError.appleScriptFailed(
                        "execution error: Safari got an error: Can’t get window id \(id). (-1728)")
                }
                let answer = urls(ofWindow: id - idBase).map { $0 + "\u{1D}" }.joined()
                if windowReads == 1 {
                    if navigateTab53AfterFirstURLRead { tab53Navigated = true }
                    if closeWindow1Tab1AfterFirstWindowRead { window1Tab1Closed = true }
                    if closeWindow1AfterFirstWindowRead { window1Closed = true }
                }
                return answer
            }
            if script.contains("get URL of tab "), script.contains("set _w to window id "),
               let id = Self.firstInt(after: "set _w to window id ", in: script),
               let t = Self.firstInt(after: "get URL of tab ", in: script) {
                lock.lock(); defer { lock.unlock() }
                let list = urls(ofWindow: id - idBase)
                guard t >= 1, t <= list.count else {
                    throw SafariBrowserError.appleScriptFailed("execution error: Invalid index. (-1719)")
                }
                return list[t - 1]
            }
            if script.contains("set windowCount to count of windows") {
                if enumerationDelay > 0 { Thread.sleep(forTimeInterval: enumerationDelay) }
                let answer = enumeration
                if closeWindow1Tab1AfterEnumeration { lock.withLock { window1Tab1Closed = true } }
                return answer
            }
            if script.contains("count of tabs of window id _id") {
                guard let n = Self.firstInt(after: "set _id to id of window ", in: script),
                      n >= 1, n <= tabCounts.count else {
                    throw SafariBrowserError.appleScriptFailed("execution error: Invalid index. (-1719)")
                }
                return "\(idBase + n)\u{1D}\(tabCounts[n - 1])"
            }
            if script.contains("index of current tab of window id _id") {
                if let n = Self.firstInt(after: "set _id to id of window ", in: script) { return "\(idBase + n)\u{1D}1" }
                if let id = Self.firstInt(after: "set _id to ", in: script) { return "\(id)\u{1D}1" }
                return ""
            }
            if script.contains("get id of window"), let n = Self.firstInt(after: "get id of window ", in: script) {
                return "\(idBase + n)"
            }
            if script.contains("do JavaScript") {
                // #221: a `wait --js` poll (its script ends in `? 'true' : ''`) has its own delay and answer.
                var waitPollAnswer: String?
                if script.contains("? 'true' : ''") {
                    let number = lock.withLock { () -> Int in waitPolls += 1; return waitPolls }
                    let delay = number <= waitPollDelays.count ? waitPollDelays[number - 1] : javaScriptDelay
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                        if Task.isCancelled { lock.withLock { cancelledDuringPoll = true } }
                    }
                    if let waitPollError { throw waitPollError }
                    waitPollAnswer = waitConditionHoldsFromPoll.map { number >= $0 } == true ? "true" : waitJavaScriptAnswer
                } else if javaScriptDelay > 0 {
                    Thread.sleep(forTimeInterval: javaScriptDelay)
                }
                if tripGuard, script.contains("index of current tab of _w") {
                    throw SafariBrowserError.appleScriptFailed(
                        "execution error: SB_TARGET_CHANGED: the anchored tab is no longer current (9001)")
                }
                if let marker = failJSContaining, script.contains(marker) {
                    if failWithTimeout { throw SafariBrowserError.processTimedOut(command: "owned-js-fixture", seconds: 30) }
                    throw SafariBrowserError.appleScriptFailed(
                        "execution error: Safari got an error: Can’t get tab. Invalid index. (-1719)")
                }
                if let waitPollAnswer { return waitPollAnswer }
                if script.contains("'SB1:OK:'") {
                    let dispatch = lock.withLock { () -> Int in wrapperDispatches += 1; return wrapperDispatches }
                    if dispatch <= guardTripsOnFirstWrapperDispatches {
                        throw SafariBrowserError.appleScriptFailed(
                            "execution error: SB_TARGET_CHANGED: URL of target tab no longer matches (9001)")
                    }
                    let isStatementForm = script.contains("var r = '' + (function(){")
                    let reply = (isStatementForm ? statementFormParses : expressionFormParses) ? inlineAnswer : ""
                    if script.contains("return _u & (character id 29) & _r") { return capturedURL + "\u{1D}" + reply }
                    return reply
                }
                if script.contains("window.__sbResult.substring(") { return "hello" }
                if script.contains("do JavaScript \"window.__sbResultLen\"") { return "5.0" }
                if script.contains("'' + window.__sbLen") { return "5.0" }
                if script.contains("do JavaScript \"window.__sbResult\"") { return storedPlainReadIsEmpty ? "" : "hello" }
                return ""
            }
            if script.contains("URL of tab 53 of window id 101") {
                if let navigatedURL {
                    let number = lock.withLock { () -> Int in plainURLReads += 1; return plainURLReads }
                    if number >= (navigatesFromURLRead ?? 1) { return navigatedURL }
                    return capturedURL
                }
                lock.lock(); defer { lock.unlock() }
                let answer = tab53Navigated ? "https://w1.example/done" : "https://w1.example/53"
                if navigateTab53AfterFirstURLRead { tab53Navigated = true }
                return answer
            }
            if script.contains("URL of") { return "https://w1.example/1" }
            return ""
        }

        private static func firstInt(after prefix: String, in text: String) -> Int? {
            guard let range = text.range(of: prefix) else { return nil }
            return Int(text[range.upperBound...].prefix(while: \.isNumber))
        }
    }

    /// What a run wrote to stdout and stderr.
    struct Output { var stdout: String; var stderr: String }

    /// Redirects a file descriptor into a pipe for the duration of one command.
    private final class FDCapture {
        private let fd: Int32
        private let pipe = Pipe()
        private var saved: Int32 = -1
        init(_ fd: Int32) { self.fd = fd }
        func start() {
            fflush(fd == STDOUT_FILENO ? stdout : stderr)
            saved = dup(fd)
            dup2(pipe.fileHandleForWriting.fileDescriptor, fd)
        }
        func stop() -> String {
            fflush(fd == STDOUT_FILENO ? stdout : stderr)
            dup2(saved, fd); close(saved)
            try? pipe.fileHandleForWriting.close()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    /// Run `safari-browser js <args>` against `fake`, dialog probe answering clear, and return what
    /// it printed. Asserting on the printed value is what keeps the protocol honest: a run that
    /// "succeeds" while printing the wrong thing is the failure these tests exist to catch.
    @discardableResult
    private func runJS(_ args: [String], on fake: FakeSafari) async throws -> Output {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try JSCommand.parse(args)
        let out = FDCapture(STDOUT_FILENO), err = FDCapture(STDERR_FILENO)
        out.start(); err.start()
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
        } catch {
            _ = err.stop(); _ = out.stop()
            throw error
        }
        let stderr = err.stop()
        return Output(stdout: out.stop(), stderr: stderr)
    }

    // MARK: - Round-trip bound at 109 tabs

    func testWindowTabTargetNeedsOneAnchorAndOneJavaScriptAt109Tabs() async throws {
        let fake = FakeSafari()
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n", "the value the wrapper answered is what gets printed")
        XCTAssertEqual(fake.enumerations, 0,
                       "#255: --window N --tab-in-window M anchors with one small read, not a 109-tab enumeration")
        XCTAssertEqual(fake.tabAnchors.count, 1, fake.transcript)
        XCTAssertEqual(fake.javaScripts.count, 1, "#255: a successful run is one `do JavaScript`:\n\(fake.transcript)")
        XCTAssertEqual(fake.scripts.count, 2, "one anchor + one JavaScript, nothing else:\n\(fake.transcript)")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 53 of window id 101"),
                          "every step must address the anchored tab: \(script)")
            XCTAssertTrue(script.contains("set _u to URL of tab 53 of window id 101"),
                          "the URL is read in the same AppleScript, not in a round trip of its own: \(script)")
            // An explicit tab position is positional by design (#79): tab 53
            // need not be the current tab, so no current-tab guard.
            XCTAssertFalse(script.contains("index of current tab"), script)
        }
    }

    func testDefaultTargetNeverEnumerates() async throws {
        let fake = FakeSafari()
        let output = try await runJS(["location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(fake.enumerations, 0, "the default target needs no enumeration at all")
        XCTAssertEqual(fake.anchors.count, 1, "one anchor round-trip at the command boundary")
        XCTAssertEqual(fake.scripts.count, 2,
            "#255: anchor + ONE JavaScript; anything more is a per-step round-trip coming back:\n\(fake.transcript)")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("window id 101"), script)
            XCTAssertTrue(script.contains("index of current tab of _w) is not 1"),
                          "every step must check the anchored tab is still the window's current tab: \(script)")
        }
    }

    func testWindowIndexTargetNeverEnumerates() async throws {
        let fake = FakeSafari()
        try await runJS(["--window", "3", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 0)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("window id 103"), script)
            XCTAssertTrue(script.contains("index of current tab of _w) is not 1"), script)
        }
    }

    func testLargePathAnchorsWithoutEnumeratingToo() async throws {
        // #255: `--large` shares the command-boundary anchor, so it gets the cheap anchor as well.
        let fake = FakeSafari()
        try await runJS(["--large", "--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 0)
        XCTAssertEqual(fake.tabAnchors.count, 1, fake.transcript)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 53 of window id 101"), script)
        }
    }

    // MARK: - #255: the one-call protocol

    func testStatementCodeRunsAsAStatementOnceAndPrintsItsValue() async throws {
        let fake = FakeSafari()
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "var a = 1; a"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(fake.javaScripts.count, 1, "the local hint saves the expression attempt that cannot parse:\n\(fake.transcript)")
        let first = try XCTUnwrap(fake.javaScripts.first, fake.transcript)
        XCTAssertTrue(first.contains("var r = '' + (function(){"), first)
    }

    func testAFormTheHintSaysParsesIsNeverFollowedByTheOtherOne() async {
        // `location.host` parses as an expression, so if no reply comes back the code ran (or the
        // page moved). Running it again as a statement would run it twice (#255 review).
        let fake = FakeSafari()
        fake.expressionFormParses = false     // the reply never arrives
        fake.capturedURL = "https://w1.example/53"
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
            XCTFail("a reply that never came back, with the URL unchanged, is an error")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, JSCommand.noReplyMessage)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.javaScripts.count, 1, "the code must not run a second time:\n\(fake.transcript)")
    }

    func testCodeThatParsesNowhereTriesBothFormsWithANavigationCheckBetween() async throws {
        let fake = FakeSafari()
        fake.expressionFormParses = false
        fake.statementFormParses = false
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "1 +"], on: fake)
            XCTFail("expected the syntax error")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("JavaScript syntax error:"), message)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.javaScripts.count, 2, "neither parsed here, so neither can have run: both are tried")
        XCTAssertTrue(fake.javaScripts[1].contains("var r = '' + (function(){"), "the second form is the statement form")
        XCTAssertFalse(fake.javaScripts[1].contains("set _u to"), "only the first call reads the URL")
        let firstJS = try XCTUnwrap(fake.scripts.firstIndex { $0.contains("do JavaScript") })
        let urlRead = try XCTUnwrap(fake.scripts.indices.first { $0 > firstJS && !fake.scripts[$0].contains("do JavaScript") })
        let lastJS = try XCTUnwrap(fake.scripts.lastIndex { $0.contains("do JavaScript") })
        XCTAssertLessThan(urlRead, lastJS,
                          "#82: the navigation check sits between the two forms, so a form that ran and navigated is not run twice (a same-URL reload is not caught)")
    }

    func testCodeThatNavigatedIsReportedAndNeverRunAgain() async throws {
        let fake = FakeSafari()
        fake.expressionFormParses = false     // the reply was lost with the old document
        fake.navigatedURL = "https://w1.example/done"
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.href = '/done'"], on: fake)
        XCTAssertEqual(output.stdout, "", "a navigation prints no value")
        XCTAssertEqual(fake.javaScripts.count, 1,
                       "#82: a navigation is a successful outcome; retrying would run the code twice:\n\(fake.transcript)")
    }

    func testNavigatingAwayFromABlankTabIsStillANavigation() async throws {
        // A tab with no URL reads as "" before the run; leaving it must be detected, not
        // mistaken for "URL unknown" (the reviewer's Start Page case).
        let fake = FakeSafari()
        fake.expressionFormParses = false
        fake.capturedURL = ""
        fake.navigatedURL = "https://w1.example/done"
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.href = '/done'"], on: fake)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
    }

    func testAFormThatNavigatedIsAlsoCaughtAfterTheSecondForm() async throws {
        // #82: with neither form known to parse, the statement form may be the one that navigated.
        // The first check sees the tab where it was, the second form runs, and the second check
        // finds it elsewhere: that is a navigation, not a syntax error.
        let fake = FakeSafari()
        fake.expressionFormParses = false
        fake.statementFormParses = false      // both replies are lost
        fake.navigatedURL = "https://w1.example/done"
        fake.navigatesFromURLRead = 2
        try await runJS(["--window", "1", "--tab-in-window", "53", "1 +"], on: fake)
        XCTAssertEqual(fake.javaScripts.count, 2, fake.transcript)
    }

    func testAReplyWhoseLengthDisagreesWithItsPayloadIsAnErrorAndNotRunAgain() async {
        let fake = FakeSafari()
        fake.inlineAnswer = "SB1:OK:50:hello\u{1E}"
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
            XCTFail("a cut reply must not print as if it were the result")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("JavaScript reply damaged:"), message)
            XCTAssertTrue(message.contains("50") && message.contains("5"), message)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
    }

    func testAResultThatEndsInNewlinesPrintsWhatItAlwaysPrinted() async throws {
        // The runner used to remove the result's own last newline; the reply now carries it intact
        // and the command drops exactly one, so the output is byte for byte what it was.
        let fake = FakeSafari()
        fake.inlineAnswer = "SB1:OK:3:a\n\n\u{1E}"
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "a\n\n", "the value `a\n` plus the newline `print` adds")
    }

    func testARuntimeErrorComesFromTheSingleReply() async {
        let fake = FakeSafari()
        fake.inlineAnswer = "SB1:ERR:boom"
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
            XCTFail("expected the runtime error")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "JavaScript error: boom")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.javaScripts.count, 1, "no read-back and no cleanup for an error either:\n\(fake.transcript)")
    }

    func testAnOversizedResultIsReadFromTheGlobalsThenCleanedUp() async throws {
        let fake = FakeSafari()
        fake.inlineAnswer = "SB1:BIG:200000:"
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(fake.javaScripts.count, 3, "wrapper, read the stored result, cleanup:\n\(fake.transcript)")
        guard fake.javaScripts.count == 3 else { return }
        XCTAssertTrue(fake.javaScripts[1].contains("window.__sbResult"), fake.javaScripts[1])
        XCTAssertTrue(fake.javaScripts[2].contains("delete window.__sbLen; delete window.__sbResult"), fake.javaScripts[2])
    }

    func testAnOversizedResultWhosePlainReadComesBackEmptyFallsBackToChunksAndSaysSo() async throws {
        let fake = FakeSafari()
        fake.inlineAnswer = "SB1:BIG:5:"
        fake.storedPlainReadIsEmpty = true
        let output = try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertTrue(output.stderr.contains("output was large, used chunked read"), output.stderr)
        XCTAssertTrue(fake.javaScripts.last?.contains("delete window.__sbLen; delete window.__sbResult") == true,
                      "the cleanup still runs after the chunked read:\n\(fake.transcript)")
    }

    // MARK: - #255: `--url` targets (URL guard + bounded retry) carry the URL read too

    func testAUrlTargetReadsTheURLBeforeItsGuardAndPrintsTheValue() async throws {
        let fake = FakeSafari()
        let output = try await runJS(["--url", "w1.example/53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
        let script = try XCTUnwrap(fake.javaScripts.first)
        let urlRead = try XCTUnwrap(script.range(of: "set _u to URL of"))
        let guardAt = try XCTUnwrap(script.range(of: "SB_TARGET_CHANGED"))
        let run = try XCTUnwrap(script.range(of: "set _r to do JavaScript"))
        XCTAssertLessThan(urlRead.lowerBound, guardAt.lowerBound,
                          "the guard must sit right before the code it protects: \(script)")
        XCTAssertLessThan(guardAt.lowerBound, run.lowerBound, script)
    }

    func testTheBoundedRetryAfterAGuardTripStillReturnsTheCapturedURLAndTheValue() async throws {
        let fake = FakeSafari()
        fake.guardTripsOnFirstWrapperDispatches = 1
        let output = try await runJS(["--url", "w1.example/53", "location.host"], on: fake)
        XCTAssertEqual(output.stdout, "hello\n", "the retry's `URL GS reply` must be split, not printed raw")
        XCTAssertEqual(fake.javaScripts.count, 2, fake.transcript)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("return _u & (character id 29) & _r"), script)
        }
    }

    func testAFlaglessRunWithNoReplyAndAnUnchangedURLIsAnErrorToo() async {
        let fake = FakeSafari()
        fake.expressionFormParses = false
        fake.capturedURL = "https://w1.example/1"       // what the fake answers for a plain URL read
        do {
            try await runJS(["location.host"], on: fake)
            XCTFail("expected the no-reply error")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, JSCommand.noReplyMessage)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
    }

    func testWindowTabWithAProfileStillEnumeratesBecauseTheIndexCountsOnlyThatProfile() async throws {
        let fake = FakeSafari()
        try await runJS(["--profile", "個人", "--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, fake.transcript)
        XCTAssertEqual(fake.tabAnchors.count, 0, fake.transcript)
    }

    func testWindowTabWithAProfileNeverTakesTheCheapAnchorEvenWithoutWindowIDs() async throws {
        // A legacy enumeration record has no window id, so the profile-scoped target comes back
        // positional. The window index counts only that profile's windows, so Safari's own index
        // must not be used to anchor it: this guard is the only thing standing between the cheap
        // read and another profile's window.
        let fake = FakeSafari()
        fake.legacyEnumeration = true
        try await runJS(["--profile", "個人", "--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(fake.tabAnchors.count, 0, "no cheap anchor with a profile:\n\(fake.transcript)")
        XCTAssertGreaterThanOrEqual(fake.enumerations, 1, fake.transcript)
    }

    func testATabOutsideTheWindowFallsBackToTheEnumerationAndItsError() async {
        let fake = FakeSafari()
        do {
            try await runJS(["--window", "2", "--tab-in-window", "9", "location.host"], on: fake)
            XCTFail("window 2 has two tabs")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound(let pattern, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pattern, "window 2 tab 9 (window has 2 tab(s))")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.tabAnchors.count, 1)
        XCTAssertEqual(fake.enumerations, 1, "the enumeration words the error exactly as before")
        XCTAssertTrue(fake.javaScripts.isEmpty, fake.transcript)
    }

    func testAWindowThatDoesNotExistAlsoFallsBackToTheEnumeration() async {
        let fake = FakeSafari()
        do {
            try await runJS(["--window", "9", "--tab-in-window", "1", "location.host"], on: fake)
            XCTFail("there are five windows")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(fake.enumerations, 1)
    }

    // MARK: - --profile: anchor by the resolved window's id (verify R1 SEC-L1)

    func testProfileWindowTargetAnchorsByWindowIDNotIndex() async throws {
        let fake = FakeSafari()
        try await runJS(["--profile", "個人", "--window", "2", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, "the profile filter needs exactly one enumeration:\n\(fake.transcript)")
        XCTAssertEqual(fake.anchors.count, 1, fake.transcript)
        XCTAssertTrue(fake.anchors[0].contains("set _id to 102"),
                      "a z-order index read after the enumeration can point at another profile's window: \(fake.anchors[0])")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("window id 102"), script)
        }
    }

    // MARK: - A vanished anchored tab must not list every window (verify R1 SEC-M1)

    func testVanishedDefaultTabDoesNotListOtherWindowsURLs() async {
        let fake = FakeSafari(failJSContaining: "'SB1:OK:'")
        do {
            try await runJS(["location.host"], on: fake)
            XCTFail("expected the vanished tab to fail the command")
        } catch let error as SafariBrowserError {
            guard case .anchoredTargetChanged = error else {
                return XCTFail("expected anchoredTargetChanged, got \(error)")
            }
            XCTAssertEqual(fake.enumerations, 0,
                           "the failure path must not pay the enumeration #180 removed, only to discard it")
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("w2.example"), "must not list other windows' tabs:\n\(text)")
            XCTAssertFalse(text.contains("w1.example/2"), "must not list other tabs:\n\(text)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testVanishedWindowTabNamesTheOriginalTarget() async {
        let fake = FakeSafari(failJSContaining: "'SB1:OK:'")
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
            XCTFail("expected the vanished tab to fail the command")
        } catch let error as SafariBrowserError {
            guard case .anchoredTargetChanged(let target) = error else {
                return XCTFail("expected anchoredTargetChanged, got \(error)")
            }
            XCTAssertTrue(target.contains("window 1 tab 53"), target)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - The anchored current tab is re-checked on every step (verify R2)

    /// Verify R2 (Codex HIGH): anchoring by (window id, tab index) alone let a
    /// different tab take the anchored position silently — close a tab to the
    /// left and index T names the next tab. Every step now checks, in the same
    /// AppleScript, that tab T is still the window's current tab.
    func testDefaultTargetFailsClosedWhenTheAnchoredTabStopsBeingCurrent() async {
        let fake = FakeSafari()
        fake.tripGuard = true
        do {
            try await runJS(["location.host"], on: fake)
            XCTFail("a step that finds another tab at the anchored position must not proceed")
        } catch let error as SafariBrowserError {
            guard case .anchoredTargetChanged(let target) = error else {
                return XCTFail("expected anchoredTargetChanged, got \(error)")
            }
            XCTAssertTrue(target.contains("front window"), target)
            XCTAssertEqual(fake.enumerations, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - #181: one real dialog probe per js command

    /// #181: the blocking-dialog probe ran three times in one `js` command
    /// (442 + 38 + 431 ms), because it is invoked from target resolution and
    /// `js` resolved before every step, outliving the gate's 2 s cache. With
    /// the target resolved once (#180) every later step hits the cache: the
    /// probe provider must be called exactly once per command.
    func testDialogProbeRunsOncePerCommand() async throws {
        for args in [["location.host"],
                     ["--window", "3", "location.host"],
                     ["--window", "1", "--tab-in-window", "53", "location.host"],
                     ["--large", "--window", "1", "--tab-in-window", "53", "location.host"]] {
            let fake = FakeSafari()
            let probes = ProbeCounter()
            let context = DaemonRequestContext(probe: { _ in probes.hit(); return .clear }, environment: [:])
            let command = try JSCommand.parse(args)
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
            XCTAssertEqual(probes.count, 1, "\(args): \(probes.count) real probes in one command")
        }
    }

    /// The discriminating case: with a slow enumeration (0.8 s, the issue's
    /// machine took 3–4 s) resolving before every step outlives the gate's
    /// 2 s cache and probes again; resolving once does not.
    func testDialogProbeRunsOnceEvenWhenEnumerationIsSlow() async throws {
        let fake = FakeSafari()
        fake.enumerationDelay = 0.8
        let probes = ProbeCounter()
        let context = DaemonRequestContext(probe: { _ in probes.hit(); return .clear }, environment: [:])
        let command = try JSCommand.parse(["--window", "1", "--tab-in-window", "53", "location.host"])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
        XCTAssertEqual(probes.count, 1, "\(probes.count) real probes — the probe cache expired between per-step resolutions")
    }

    func testDialogProbeRunsOnceEvenWhenJavaScriptOutlivesCacheTTL() async throws {
        let fake = FakeSafari()
        fake.javaScriptDelay = 0.55
        let probes = ProbeCounter()
        let context = DaemonRequestContext(probe: { _ in probes.hit(); return .clear }, environment: [:])
        let command = try JSCommand.parse(["--window", "1", "--tab-in-window", "53", "location.host"])
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
        XCTAssertEqual(probes.count, 1, "a slow JavaScript command must not start another full probe after the TTL")
    }

    func testTimedOutJavaScriptKeepsOriginalFailureWithoutASecondProbe() async throws {
        let fake = FakeSafari(failJSContaining: "'SB1:OK:'")
        fake.failWithTimeout = true
        let probes = ProbeCounter()
        let context = DaemonRequestContext(probe: { _ in probes.hit(); return .clear }, environment: [:])
        let command = try JSCommand.parse(["location.host"])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
            XCTFail("the timed-out operation must remain a failure")
        } catch SafariBrowserError.processTimedOut(let command, let seconds) {
            XCTAssertEqual(command, "owned-js-fixture")
            XCTAssertEqual(seconds, 30)
        }
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(context.gate.state(for: .id(101)), .unprobed)
    }

    final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func hit() { lock.lock(); calls += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }
}
