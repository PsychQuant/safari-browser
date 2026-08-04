import XCTest
@testable import SafariBrowser

/// #77: nested-container scrolling.
///
/// The reason this needs its own tests is that `scrollBy` reports nothing. An
/// element with no overflow and an element already at its edge both accept the
/// call, change nothing, and return undefined — so without an explicit check
/// the command would succeed silently in both cases, and the caller would be
/// left to wonder why the list never moved.
final class ContainerScrollTests: XCTestCase {

    func testDistinguishesAllThreeNoOpCauses() {
        let js = ScrollCommand.containerScrollJS(selector: ".list", x: 0, y: 300)
        XCTAssertTrue(js.contains("NOT_FOUND"), "a missing selector must be reportable")
        XCTAssertTrue(js.contains("NOT_SCROLLABLE"), "an element with no overflow must be reportable")
        XCTAssertTrue(js.contains("AT_EDGE"), "an exhausted scroll range must be reportable")
        XCTAssertTrue(js.contains("OK"))
    }

    func testDecidesByMeasuredMovementNotByCapability() {
        // Checking scrollHeight alone would call it a success whenever the
        // element *could* scroll, even when this particular call did nothing.
        // The position is sampled before and compared after.
        let js = ScrollCommand.containerScrollJS(selector: ".list", x: 0, y: 300)
        XCTAssertTrue(js.contains("beforeTop"), "movement must be measured, not inferred")
        guard let assign = js.range(of: "var beforeTop"),
              let call = js.range(of: "el.scrollBy") else {
            return XCTFail("script missing baseline capture / scroll call")
        }
        XCTAssertLessThan(assign.lowerBound, call.lowerBound,
                          "the baseline must be captured before the scroll, or it measures nothing")
    }

    func testCapabilityCheckOnlyRunsAfterMovementFails() {
        // AT_EDGE and NOT_SCROLLABLE are only distinguishable once we know the
        // element did not move; probing capability first would mislabel a
        // scrollable-but-exhausted container.
        let js = ScrollCommand.containerScrollJS(selector: ".list", x: 0, y: 300)
        guard let movement = js.range(of: "el.scrollTop !== beforeTop"),
              let capability = js.range(of: "el.scrollHeight > el.clientHeight") else {
            return XCTFail("script missing movement / capability checks")
        }
        XCTAssertLessThan(movement.lowerBound, capability.lowerBound)
    }

    func testCarriesTheRequestedDeltaBothAxes() {
        let vertical = ScrollCommand.containerScrollJS(selector: ".l", x: 0, y: -500)
        XCTAssertTrue(vertical.contains("el.scrollBy(0, -500)"), vertical)
        let horizontal = ScrollCommand.containerScrollJS(selector: ".l", x: 250, y: 0)
        XCTAssertTrue(horizontal.contains("el.scrollBy(250, 0)"), horizontal)
        // Horizontal-only scrolling must not be misreported as unscrollable on
        // a container that only overflows sideways.
        XCTAssertTrue(horizontal.contains("el.scrollWidth > el.clientWidth"))
    }
}
