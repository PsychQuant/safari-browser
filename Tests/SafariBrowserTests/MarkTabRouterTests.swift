import XCTest
@testable import SafariBrowser

/// Coverage for `TargetOptions.markTabResolved` — the precedence helper
/// that consolidates `--mark-tab` / `--mark-tab-persist` flags + env
/// variable into a single tri-state per Requirement: Marker is opt-in
/// via `--mark-tab` flag, default OFF.
final class MarkTabRouterTests: XCTestCase {

    private func makeOptions(
        markTab: Bool = false,
        markTabPersist: Bool = false,
        env: [String: String] = [:]
    ) -> TargetOptions {
        var options = TargetOptions()
        options.markTab = markTab
        options.markTabPersist = markTabPersist
        return options
    }

    // MARK: - Defaults

    func testDefault_neitherFlagNorEnv_isOff() {
        let options = makeOptions()
        XCTAssertEqual(options.markTabResolved(env: [:]), .off)
    }

    // MARK: - Flag wins

    func testFlag_markTabBare_isEphemeral() {
        let options = makeOptions(markTab: true)
        XCTAssertEqual(options.markTabResolved(env: [:]), .ephemeral)
    }

    func testFlag_markTabPersist_isPersist() {
        let options = makeOptions(markTabPersist: true)
        XCTAssertEqual(options.markTabResolved(env: [:]), .persist)
    }

    // MARK: - Env activations

    func testEnv_value1_isEphemeral() {
        let options = makeOptions()
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "1"]),
            .ephemeral
        )
    }

    func testEnv_valuePersist_isPersist() {
        let options = makeOptions()
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "persist"]),
            .persist
        )
    }

    func testEnv_value2_isPersist() {
        let options = makeOptions()
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "2"]),
            .persist
        )
    }

    func testEnv_unsetOrZero_isOff() {
        let options = makeOptions()
        XCTAssertEqual(options.markTabResolved(env: [:]), .off)
        XCTAssertEqual(options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "0"]), .off)
        XCTAssertEqual(options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": ""]), .off)
    }

    // MARK: - Precedence: flag wins over env

    func testFlag_overridesEnvOff() {
        let options = makeOptions(markTab: true)
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "0"]),
            .ephemeral,
            "flag should win when env says off"
        )
    }

    func testFlag_overridesEnvDifferentMode() {
        // --mark-tab + env=persist → flag (ephemeral) wins
        let options = makeOptions(markTab: true)
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "persist"]),
            .ephemeral
        )
    }

    func testPersistFlag_overridesEnvEphemeral() {
        let options = makeOptions(markTabPersist: true)
        XCTAssertEqual(
            options.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "1"]),
            .persist
        )
    }

    // MARK: - Mutual exclusion validation

    func testValidation_bothFlagsTogether_throws() {
        var options = makeOptions(markTab: true, markTabPersist: true)
        XCTAssertThrowsError(try options.validateMarkTabFlags())
    }

    func testValidation_singleFlag_passes() throws {
        let ephemeral = makeOptions(markTab: true)
        try ephemeral.validateMarkTabFlags()  // expect no throw

        let persist = makeOptions(markTabPersist: true)
        try persist.validateMarkTabFlags()
    }

    func testValidation_neitherFlag_passes() throws {
        let neither = makeOptions()
        try neither.validateMarkTabFlags()
    }
}
