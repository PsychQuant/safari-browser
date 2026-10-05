import XCTest
@testable import SafariBrowser

/// #190: a result that does not come back inline sits in the page until the CLI has read it. Under the
/// old fixed names two calls on one page shared that place, so a call could read what another had
/// left. Each call now owns a slot whose name nobody else uses, and every chunk read says how much it
/// carries and ends in a marker, so a cut or altered chunk is an error instead of data.
final class ResultSlotTests: XCTestCase {

    // MARK: - names

    func testFreshSlotsNeverShareAName() {
        let keys = (0..<500).map { _ in ResultSlot.make().key }
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("__sbr_"), key)
            XCTAssertNotNil(ResultSlot(pageKey: key), "a name the CLI makes must pass its own validation: \(key)")
        }
    }

    func testAPageNamedSlotIsOnlyAcceptedInTheExpectedShape() {
        XCTAssertNotNil(ResultSlot(pageKey: "__sbr_k3j2h1g0abcd"))
        // The name is pasted into scripts, so anything that is not a plain identifier is refused.
        for bad in ["", "__sbr_", "__sbr_short", "sbr_k3j2h1g0abcd", "__sbr_k3j2h1g0 abcd",
                    "__sbr_k3j2h1g0abcd;alert(1)", "__sbr_k3j2h1g0abcd'", "__sbr_k3j2h1g0abcd\"",
                    "__sbr_k3j2h1g0abcd\n", "__sbr_K3J2H1G0ABCD", "__sbr_k3j2h1g0abcd.x",
                    "__sbr_" + String(repeating: "a", count: 65), "window.__sbr_k3j2h1g0abcd"] {
            XCTAssertNil(ResultSlot(pageKey: bad), bad.debugDescription)
        }
    }

    func testNoScriptUsesTheOldSharedNames() {
        let slot = ResultSlot.make()
        let scripts = [slot.presetScript, slot.storeScript("1"), slot.lengthScript, slot.errorScript,
                       slot.readScript(offset: 0, total: 10), slot.cleanupScript]
        for script in scripts {
            XCTAssertTrue(script.contains(slot.key), script)
            for old in ["__sbResult", "__sbResultLen", "__sbLargeErr", "__sbLen"] {
                XCTAssertFalse(script.contains(old), "\(old) is shared by every call: \(script)")
            }
        }
    }

    // MARK: - two calls, one page

    private func store(_ page: FakePage, _ slot: ResultSlot, _ expression: String) {
        _ = page.evaluate(slot.storeScript(expression))
    }

    private func readAll(_ page: FakePage, _ slot: ResultSlot) throws -> String {
        let total = try XCTUnwrap(ResultSlot.parseLength(try XCTUnwrap(page.evaluate(slot.lengthScript))))
        var offset = 0, text = ""
        while offset < total {
            let raw = try XCTUnwrap(page.evaluate(slot.readScript(offset: offset, total: total)))
            let frame = try ResultSlot.parseFrame(raw, offset: offset, total: total)
            text += frame.text
            offset = frame.end
        }
        return text
    }

    func testTwoSlotsOnOnePageKeepTheirOwnResults() throws {
        let page = FakePage()
        let a = ResultSlot.make(), b = ResultSlot.make()
        store(page, a, "'first batch'")
        store(page, b, "'second batch'")
        // The shape of #190: B is stored after A, and A is read afterwards.
        XCTAssertEqual(try readAll(page, a), "first batch")
        XCTAssertEqual(try readAll(page, b), "second batch")
    }

    func testCleaningUpOneSlotLeavesTheOthersAlone() throws {
        let page = FakePage()
        let a = ResultSlot.make(), b = ResultSlot.make()
        store(page, a, "'a'"); store(page, b, "'b'")
        _ = page.evaluate(a.cleanupScript)
        XCTAssertFalse(page.has(a.key))
        XCTAssertTrue(page.has(b.key))
        XCTAssertEqual(try readAll(page, b), "b")
    }

    func testASlotThatIsGoneReadsAsAnErrorNeverAsEmptyText() throws {
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "'x'.repeat(10)")
        _ = page.evaluate(slot.cleanupScript)
        let raw = page.evaluate(slot.readScript(offset: 0, total: 10)) ?? ""
        XCTAssertThrowsError(try ResultSlot.parseFrame(raw, offset: 0, total: 10),
                             "the old read of a missing global answered nothing, which was joined into the result as ''")
    }

    func testAReadForAnotherLengthIsRefused() throws {
        // A slot that was replaced between the length read and the chunk read has another length.
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "'abcdef'")
        XCTAssertEqual(page.evaluate(slot.readScript(offset: 0, total: 99)), "")
    }

    // MARK: - what is stored

    func testALoneSurrogateIsStoredAsTheReplacementCharacter() throws {
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "'ab' + '\\uD83D' + 'cd'")
        XCTAssertEqual(page.evaluate("window.\(slot.key).text.isWellFormed()"), "true",
                       "osascript silently drops a lone surrogate; U+FFFD has the same length and survives (B7)")
        XCTAssertEqual(page.evaluate("window.\(slot.key).len"), "5")
        XCTAssertEqual(try readAll(page, slot), "ab\u{FFFD}cd")
    }

    func testAPresetSlotIsTheOneTheStoreWritesInto() throws {
        let page = FakePage()
        let slot = ResultSlot.make()
        _ = page.evaluate(slot.presetScript)
        XCTAssertEqual(page.evaluate(slot.lengthScript), "undefined", "preset: nothing stored yet")
        store(page, slot, "'abc'")
        XCTAssertEqual(try readAll(page, slot), "abc")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [slot.key], "one object, not one per script")
    }

    func testStoringAnExpressionThatThrowsLeavesNoLength() {
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "(function(){ throw new Error('x') })()")
        XCTAssertEqual(page.evaluate(slot.lengthScript), "undefined",
                       "the sentinel JSCommand reads to tell 'never ran' from 'ran and found nothing'")
    }

    // MARK: - chunks

    func testChunksNeverSplitASurrogatePair() throws {
        let page = FakePage()
        let slot = ResultSlot.make()
        // Put a pair across the first chunk boundary: unit 262143 is a high surrogate, 262144 its low.
        store(page, slot, "'a'.repeat(\(ResultSlot.chunkSize - 1)) + '\\u{1F600}' + 'b'.repeat(10)")
        let total = ResultSlot.chunkSize + 11
        let first = try XCTUnwrap(page.evaluate(slot.readScript(offset: 0, total: total)))
        let frame = try ResultSlot.parseFrame(first, offset: 0, total: total)
        XCTAssertEqual(frame.end, ResultSlot.chunkSize - 1, "the chunk ends before the pair, not in the middle of it")
        XCTAssertEqual(try readAll(page, slot), String(repeating: "a", count: ResultSlot.chunkSize - 1) + "\u{1F600}" + String(repeating: "b", count: 10))
    }

    func testANewlineAtAChunkBoundarySurvives() throws {
        // The runner drops a trailing newline of every answer, so a chunk that ended in one lost it.
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "'a'.repeat(\(ResultSlot.chunkSize - 1)) + '\\n' + 'b'.repeat(3)")
        let total = ResultSlot.chunkSize + 3
        var text = "", offset = 0
        while offset < total {
            // exactly what the runner does to the answer
            let raw = (try XCTUnwrap(page.evaluate(slot.readScript(offset: offset, total: total))) + "\n")
                .replacingOccurrences(of: "\\n$", with: "", options: .regularExpression)
            let frame = try ResultSlot.parseFrame(raw, offset: offset, total: total)
            text += frame.text; offset = frame.end
        }
        XCTAssertEqual(text, String(repeating: "a", count: ResultSlot.chunkSize - 1) + "\n" + "bbb")
    }

    func testTrailingWhitespaceSurvivesTheDaemonTrim() throws {
        let page = FakePage()
        let slot = ResultSlot.make()
        store(page, slot, "'x  \\n\\n  '")
        let raw = try XCTUnwrap(page.evaluate(slot.readScript(offset: 0, total: 7)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try ResultSlot.parseFrame(raw, offset: 0, total: 7).text, "x  \n\n  ")
    }

    // MARK: - frames that did not arrive intact

    func testParseFrameRefusesAnythingThatIsNotWhatTheScriptSends() {
        let end = "\u{1E}"
        let bad: [String] = ["", "5", "5:hello", "5:hello\(end)x",
                             "5:hellox", "5:hello ", "5:hello\n", "5:hello:",   // the right length, but nothing ends it
                             "6:hello\(end)", "4:hello\(end)", "5:hell\(end)",
                             ":hello\(end)", "-5:hello\(end)", "+5:hello\(end)", "5 :hello\(end)", "99:hello\(end)",
                             "0:\(end)", "undefined", "missing value"]
        for raw in bad {
            XCTAssertThrowsError(try ResultSlot.parseFrame(raw, offset: 0, total: 5), raw.debugDescription)
        }
        XCTAssertEqual(try ResultSlot.parseFrame("5:hello\(end)", offset: 0, total: 5).text, "hello")
        // a position past the announced total is refused even when the text is as long as the frame says
        XCTAssertThrowsError(try ResultSlot.parseFrame("8:hello\(end)", offset: 3, total: 5))
        // a frame must end at the position it announces, counted from where it started
        XCTAssertThrowsError(try ResultSlot.parseFrame("8:hello\(end)", offset: 4, total: 9))
        XCTAssertEqual(try ResultSlot.parseFrame("9:hello\(end)", offset: 4, total: 9).end, 9)
    }

    func testParseFrameCountsUTF16UnitsAndKeepsCombiningMarksAfterTheColon() throws {
        let end = "\u{1E}"
        XCTAssertEqual(try ResultSlot.parseFrame("2:\u{1F600}\(end)", offset: 0, total: 2).text, "\u{1F600}")
        // a combining mark directly after `:` fuses with it into one Character; the frame is read by scalar
        XCTAssertEqual(try ResultSlot.parseFrame("2:\u{0301}x\(end)", offset: 0, total: 2).text, "\u{0301}x")
        XCTAssertEqual(try ResultSlot.parseFrame("1:\u{FE0F}\(end)", offset: 0, total: 1).text, "\u{FE0F}")
    }

    func testParseFrameKeepsAnEndMarkerThatIsPartOfTheText() throws {
        let end = "\u{1E}"
        XCTAssertEqual(try ResultSlot.parseFrame("3:a\(end)b\(end)", offset: 0, total: 3).text, "a\(end)b")
    }

    // MARK: - evidence that the code started (#257 B2)

    func testProgressIsReadFromTheSlotAlone() {
        let page = FakePage()
        let slot = ResultSlot.make()
        XCTAssertEqual(ResultSlot.parseProgress(page.evaluate(slot.progressScript) ?? ""), .gone, "no slot: the page was replaced")
        _ = page.evaluate(slot.presetScript)
        XCTAssertEqual(ResultSlot.parseProgress(page.evaluate(slot.progressScript) ?? ""), .notStarted)
        _ = page.evaluate("window.\(slot.key).started = true")
        XCTAssertEqual(ResultSlot.parseProgress(page.evaluate(slot.progressScript) ?? ""), .started(length: nil))
        _ = page.evaluate(slot.storeScript("'abc'"))
        XCTAssertEqual(ResultSlot.parseProgress(page.evaluate(slot.progressScript) ?? ""), .started(length: 3))
    }

    func testAnAnswerThatIsNotOneOfTheThreeReadsAsGoneWhichNeverRunsAnything() {
        for raw in ["", "missing value", "garbage", "started", "idle", "Started:1"] {
            let progress = ResultSlot.parseProgress(raw)
            XCTAssertTrue(progress == .gone || { if case .started = progress { return true }; return false }(), "\(raw.debugDescription) → \(progress)")
            XCTAssertNotEqual(progress, .notStarted, "\(raw.debugDescription): only a clear 'idle:undefined' may let the other form run")
        }
        XCTAssertEqual(ResultSlot.parseProgress(" idle:undefined \n"), .notStarted)
        XCTAssertEqual(ResultSlot.parseProgress("idle:5"), .started(length: 5), "a length without a start cannot come from a wrapper; if it does, something ran")
        XCTAssertEqual(ResultSlot.parseProgress("started:5.0"), .started(length: 5))
    }

    func testAnErrorIsToldFromNoErrorByItsPrefix() {
        XCTAssertEqual(ResultSlot.parseError("E:boom"), "boom")
        XCTAssertEqual(ResultSlot.parseError("E:"), "", "an error whose message is empty is still an error")
        XCTAssertNil(ResultSlot.parseError("undefined"))
        XCTAssertNil(ResultSlot.parseError(""))
        XCTAssertNil(ResultSlot.parseError("boom"))
    }

    // MARK: - lengths

    func testParseLengthReadsWhatAppleScriptPrintsForANumber() {
        XCTAssertEqual(ResultSlot.parseLength("5489.0"), 5489)
        XCTAssertEqual(ResultSlot.parseLength("5489"), 5489)
        XCTAssertEqual(ResultSlot.parseLength(" 12 \n"), 12)
        XCTAssertEqual(ResultSlot.parseLength("0"), 0)
        for none in ["undefined", "", "missing value", "-3", "NaN", "abc", "5.5", "1e400"] {
            XCTAssertNil(ResultSlot.parseLength(none), none)
        }
    }
}
