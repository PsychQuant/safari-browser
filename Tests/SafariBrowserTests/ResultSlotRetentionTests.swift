import XCTest
@testable import SafariBrowser

/// #193: a slot a call could not remove (the process was killed, the call was cancelled, the page changed before
/// the removal) used to stay in the page until the page was left. Now a call that makes a slot also removes the
/// slots that nobody has used for 600000 milliseconds, judged by the page's own clock. These tests drive that
/// clock (`Date.now`) to places a real page would take minutes to reach.
final class ResultSlotRetentionTests: XCTestCase, @unchecked Sendable {

    private let retention = 600_000

    private func page(clock: Int = 1_000_000) -> FakePage {
        let page = FakePage()
        _ = page.evaluate("var __clock = \(clock); Date.now = function(){ return __clock; };")
        return page
    }

    private func setClock(_ page: FakePage, _ value: Int) { _ = page.evaluate("__clock = \(value);") }

    /// What a call that makes a slot, by each of the three ways a call makes one.
    private enum Maker: CaseIterable { case inline, store, preset }

    /// Make a slot the way a call does and return its name.
    @discardableResult
    private func makeSlot(_ page: FakePage, by maker: Maker) throws -> String {
        switch maker {
        case .inline:
            let reply = try XCTUnwrap(page.evaluate(JSWrapper.inlineExpression("'x'.repeat(200000)")))
            guard case .stored(let slot, _) = JSWrapper.parseInline(reply) else { XCTFail("not parked: \(reply.prefix(60))"); return "" }
            return slot.key
        case .store:
            let slot = ResultSlot.make()
            _ = page.evaluate(slot.storeScript("'stored'"))
            return slot.key
        case .preset:
            let slot = ResultSlot.make()
            _ = page.evaluate(slot.presetScript)
            return slot.key
        }
    }

    private func slots(_ page: FakePage) -> Set<String> { Set(page.keys(withPrefix: ResultSlot.keyPrefix)) }

    // MARK: - an abandoned slot is removed by the next call that makes one

    func testAnAbandonedSlotIsRemovedByTheNextCallThatMakesOne() throws {
        for maker in Maker.allCases {
            let page = page()
            let abandoned = try makeSlot(page, by: .inline)
            setClock(page, 1_000_000 + retention + 1)
            let next = try makeSlot(page, by: maker)
            XCTAssertEqual(slots(page), [next], "\(maker): the abandoned slot should be gone")
            XCTAssertFalse(page.has(abandoned), "\(maker)")
        }
    }

    func testASlotUsedWithinTheRetentionStaysAndOneBeyondItGoes() throws {
        let page = page()
        let at = try makeSlot(page, by: .inline)
        setClock(page, 1_000_000 + retention)
        let sweep1 = try makeSlot(page, by: .store)
        XCTAssertTrue(page.has(at), "exactly 600000 ms is not older than 600000 ms")
        setClock(page, 1_000_000 + retention + 1)
        _ = try makeSlot(page, by: .store)
        XCTAssertFalse(page.has(at))
        XCTAssertTrue(page.has(sweep1), "made at 1600000, only 1 ms old")
    }

    // MARK: - a slot in use is not removed

    func testEveryReadKeepsTheSlotAlive() throws {
        let reads: [(String, (ResultSlot) -> String)] = [
            ("length", { $0.lengthScript }),
            ("error", { $0.errorScript }),
            ("progress", { $0.progressScript }),
            ("chunk", { $0.readScript(offset: 0, total: 6) }),
        ]
        for (name, script) in reads {
            let page = page()
            let slot = ResultSlot.make()
            _ = page.evaluate(slot.storeScript("'stored'"))
            setClock(page, 1_000_000 + retention - 10)
            _ = page.evaluate(script(slot))
            setClock(page, 1_000_000 + retention + 10)       // 20 ms after the last read, beyond the retention after the make
            _ = try makeSlot(page, by: .inline)
            XCTAssertTrue(page.has(slot.key), "a \(name) read must count as a use")
        }
    }

    /// The case the touching is for: a result read in several chunks over more page time than the retention,
    /// while other calls make slots in the same page.
    func testALongReadSurvivesOtherCallsMakingSlotsInTheMiddleOfIt() async throws {
        for transport in [FakePage.Transport.stateless, .daemon] {          // the daemon trims whitespace of an answer
            let page = page()
            page.transport = transport
            var clock = 1_000_000
            var chunkReads = 0
            page.beforeRun = { script in
                guard script.contains("substring(") else { return }
                chunkReads += 1
                clock += 400_000                                   // 400 s between two reads, 1600 s in all
                self.setClock(page, clock)
                _ = try? self.makeSlot(page, by: .store)          // another call makes a slot and reclaims
            }
            let result = try await withBridge(page) {
                try await SafariBridge.doJavaScriptLarge("'x'.repeat(1000000)")
            }
            XCTAssertEqual(result.utf16.count, 1_000_000, "\(transport)")
            XCTAssertGreaterThanOrEqual(chunkReads, 4, "\(transport)")
        }
    }

    func testTwoCallsAtTheSameMomentDoNotRemoveEachOther() throws {
        let page = page()
        let a = try makeSlot(page, by: .inline)
        setClock(page, 1_000_001)
        let b = try makeSlot(page, by: .inline)
        XCTAssertEqual(slots(page), [a, b])
    }

    // MARK: - what is not an abandoned slot

    func testOnlyAbandonedSlotsOfThisVersionAreRemoved() throws {
        let page = page()
        _ = page.evaluate("""
            window.__sbr_legacyslot01 = { text: 'x', len: 1 };
            window.__sbr_stringstamp1 = { text: 'x', len: 1, u: 'old' };
            window.__sbr_nanstamp0001 = { text: 'x', len: 1, u: NaN };
            window.__sbr_nullstamp001 = { text: 'x', len: 1, u: null };
            window.__sbr_zerostring01 = { text: 'x', len: 1, u: '0' };
            window.__sbr_truestamp001 = { text: 'x', len: 1, u: true };
            window.__sbr_arraystamp01 = { text: 'x', len: 1, u: [] };
            window.__sbr_notanobject1 = 5;
            window.__sbr_nothing00001 = null;
            window.__sbr_functionval1 = Object.assign(function(){}, { u: 0 });
            window.other_slot = { u: 0 };
            window.__sbrnotprefixed1 = { u: 0 };
            """)
        setClock(page, 1_000_000 + 5 * retention)
        let next = try makeSlot(page, by: .inline)
        XCTAssertEqual(slots(page), ["__sbr_legacyslot01", "__sbr_stringstamp1", "__sbr_nanstamp0001", "__sbr_nullstamp001",
                                     "__sbr_zerostring01", "__sbr_truestamp001", "__sbr_arraystamp01", "__sbr_notanobject1",
                                     "__sbr_nothing00001", "__sbr_functionval1", next])
        XCTAssertTrue(page.has("other_slot"))
        XCTAssertTrue(page.has("__sbrnotprefixed1"))
    }

    // MARK: - a page that does not keep a clock

    func testAClockThatDoesNotTellTheTimeRemovesNothingAndBreaksNothing() throws {
        // `Infinity` and `-Infinity` are the inputs a number check alone does not stop: every stamp is older than
        // `Infinity - 600000`. A numeric string and `null` are numbers to a careless comparison.
        let stubs = ["Date.now = function(){ throw new Error('no clock'); }",
                     "Date.now = function(){ return 'noon'; }",
                     "Date.now = function(){ return '1e15'; }",
                     "Date.now = function(){ return null; }",
                     "Date.now = function(){ return NaN; }",
                     "Date.now = function(){ return Infinity; }",
                     "Date.now = function(){ return -Infinity; }"]
        for stub in stubs {
            let page = page()
            let abandoned = try makeSlot(page, by: .inline)
            let inUse = try makeSlot(page, by: .store)
            _ = page.evaluate(stub)
            for maker in Maker.allCases {
                let key = try makeSlot(page, by: maker)           // the call completes
                XCTAssertTrue(page.has(key), "\(stub) / \(maker)")
                XCTAssertEqual(page.evaluate("typeof window.\(key).u"), "undefined", "\(stub) / \(maker): no stamp from a clock that cannot be read")
            }
            XCTAssertTrue(page.has(abandoned), "\(stub): nothing is removed because of a clock that cannot be read")
            XCTAssertTrue(page.has(inUse), stub)
        }
    }

    /// A slot made under a clock that could not be read has no stamp and stays; the slots that have one are
    /// reclaimed again as soon as the clock is readable.
    func testReclaimingWorksAgainWhenTheClockComesBack() throws {
        let page = page()
        let old = try makeSlot(page, by: .inline)
        _ = page.evaluate("Date.now = function(){ return Infinity; }")
        let unstamped = try makeSlot(page, by: .inline)
        _ = page.evaluate("Date.now = function(){ return __clock; }")
        setClock(page, 1_000_000 + retention + 1)
        let next = try makeSlot(page, by: .inline)
        XCTAssertEqual(slots(page), [unstamped, next])
        XCTAssertFalse(page.has(old))
    }

    /// The stated limit, pinned: a clock that jumps forward by more than the retention makes a slot in use look
    /// old, and the next call that makes a slot removes it. The call that was reading it fails closed.
    func testAClockThatJumpsForwardRemovesASlotThatIsInUse() throws {
        let page = page()
        let reading = ResultSlot.make()
        _ = page.evaluate(reading.storeScript("'stored'"))
        setClock(page, 1_000_000 + 10 * retention)
        _ = try makeSlot(page, by: .inline)
        XCTAssertFalse(page.has(reading.key))
        XCTAssertEqual(page.evaluate(reading.readScript(offset: 0, total: 6)), "", "a read of a slot that is gone answers an empty text, which the reader reports as an incomplete transfer")
    }

    func testAClockThatStandsStillOrRunsBehindRemovesNothing() throws {
        for later in [1_000_000, 1_000_000 - retention, 0] {
            let page = page()
            let slot = try makeSlot(page, by: .inline)
            setClock(page, later)
            _ = try makeSlot(page, by: .inline)
            XCTAssertTrue(page.has(slot), "clock \(later)")
        }
    }

    func testAPageWithoutAnyClockStillParksAndReadsAResult() async throws {
        let page = FakePage()
        _ = page.evaluate("Date = undefined;")
        let reply = try XCTUnwrap(page.evaluate(JSWrapper.inlineExpression("'x'.repeat(200000)")))
        guard case .stored(let slot, _) = JSWrapper.parseInline(reply) else { return XCTFail("not parked: \(reply.prefix(60))") }
        XCTAssertEqual(page.evaluate("typeof window.\(slot.key).u"), "undefined")
        let read = try await withBridge(page) { try await SafariBridge.doJavaScriptLarge("'y'.repeat(300000)") }
        XCTAssertEqual(read.utf16.count, 300_000)
    }

    // MARK: -

    private func withBridge<T: Sendable>(_ page: FakePage, _ body: @Sendable () async throws -> T) async rethrows -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try page.respond($0) }) { try await body() }
        }
    }
}
