import XCTest
@testable import SafariBrowser

/// Comprehensive coverage for the `exec` script-interpreter core. Tests
/// the pieces that are independent of `SafariBridge` so they run without
/// a live Safari: parser, variable store, expression evaluator, max-steps
/// cap, and the result-shape conventions.
///
/// Subprocess dispatch (`CommandDispatch.dispatch`) is exercised by the
/// integration script `Tests/e2e-exec-script.sh`; here we limit ourselves
/// to the deterministic in-process logic.
final class ScriptInterpreterTests: XCTestCase {

    // MARK: - Parser

    func testParser_rejectsNonArrayRoot() {
        let cases: [String] = [
            "{\"cmd\":\"get\"}",
            "\"not an array\"",
            "42",
        ]
        for source in cases {
            XCTAssertThrowsError(
                try ScriptInterpreter.parseScript(source: source, maxSteps: 100),
                "non-array root should be rejected: \(source)"
            ) { error in
                guard case ScriptParseError.invalidScriptFormat = error else {
                    return XCTFail("expected invalidScriptFormat, got \(error)")
                }
            }
        }
    }

    func testParser_rejectsEmptyInput() {
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(source: "   \n", maxSteps: 100)) { error in
            guard case ScriptParseError.invalidScriptFormat = error else {
                return XCTFail("expected invalidScriptFormat, got \(error)")
            }
        }
    }

    func testParser_acceptsEmptyArray() throws {
        let steps = try ScriptInterpreter.parseScript(source: "[]", maxSteps: 100)
        XCTAssertEqual(steps.count, 0)
    }

    func testParser_acceptsMinimalStep() throws {
        let steps = try ScriptInterpreter.parseScript(
            source: "[{\"cmd\":\"get url\"}]",
            maxSteps: 100
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].cmd, "get url")
        XCTAssertEqual(steps[0].args, [])
        XCTAssertNil(steps[0].varName)
        XCTAssertNil(steps[0].ifExpression)
        XCTAssertEqual(steps[0].onError, .abort)
    }

    func testParser_acceptsAllKeys() throws {
        let source = """
        [{
            "cmd": "click",
            "args": ["button.upload"],
            "var": "result",
            "if": "$url contains \\"plaud\\"",
            "onError": "continue"
        }]
        """
        let steps = try ScriptInterpreter.parseScript(source: source, maxSteps: 100)
        XCTAssertEqual(steps[0].cmd, "click")
        XCTAssertEqual(steps[0].args, ["button.upload"])
        XCTAssertEqual(steps[0].varName, "result")
        XCTAssertEqual(steps[0].ifExpression, "$url contains \"plaud\"")
        XCTAssertEqual(steps[0].onError, .continue)
    }

    func testParser_rejectsUnknownStepKey() {
        let source = """
        [{"cmd": "click", "command": "button"}]
        """
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(source: source, maxSteps: 100)) { error in
            guard case ScriptParseError.invalidStepSchema(let msg) = error else {
                return XCTFail("expected invalidStepSchema, got \(error)")
            }
            XCTAssertTrue(msg.contains("'command'"), "message should name the unknown key, got: \(msg)")
            XCTAssertTrue(msg.contains("step 0"), "message should include the step index, got: \(msg)")
        }
    }

    func testParser_rejectsMissingCmd() {
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(
            source: "[{\"args\":[\"x\"]}]",
            maxSteps: 100
        )) { error in
            guard case ScriptParseError.invalidStepSchema = error else {
                return XCTFail("expected invalidStepSchema, got \(error)")
            }
        }
    }

    func testParser_rejectsArgsThatAreNotStrings() {
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(
            source: "[{\"cmd\":\"click\",\"args\":[1,2]}]",
            maxSteps: 100
        )) { error in
            guard case ScriptParseError.invalidStepSchema = error else {
                return XCTFail("expected invalidStepSchema, got \(error)")
            }
        }
    }

    func testParser_rejectsInvalidOnError() {
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(
            source: "[{\"cmd\":\"click\",\"onError\":\"retry\"}]",
            maxSteps: 100
        )) { error in
            guard case ScriptParseError.invalidStepSchema = error else {
                return XCTFail("expected invalidStepSchema, got \(error)")
            }
        }
    }

    // MARK: - Max-steps cap

    func testParser_defaultCapEnforced() {
        let stepJSON = (0..<1001).map { _ in "{\"cmd\":\"get url\"}" }.joined(separator: ",")
        let source = "[\(stepJSON)]"
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(
            source: source,
            maxSteps: ScriptInterpreter.defaultMaxSteps
        )) { error in
            guard case ScriptParseError.maxStepsExceeded(let actual, let cap) = error else {
                return XCTFail("expected maxStepsExceeded, got \(error)")
            }
            XCTAssertEqual(actual, 1001)
            XCTAssertEqual(cap, 1000)
        }
    }

    func testParser_overrideAllowsHigherCap() throws {
        let stepJSON = (0..<1500).map { _ in "{\"cmd\":\"get url\"}" }.joined(separator: ",")
        let source = "[\(stepJSON)]"
        let steps = try ScriptInterpreter.parseScript(source: source, maxSteps: 5000)
        XCTAssertEqual(steps.count, 1500)
    }

    func testParser_overrideBelowDefaultStillEnforced() {
        let stepJSON = (0..<11).map { _ in "{\"cmd\":\"get url\"}" }.joined(separator: ",")
        let source = "[\(stepJSON)]"
        XCTAssertThrowsError(try ScriptInterpreter.parseScript(source: source, maxSteps: 10))
    }

    // MARK: - Variable store

    func testVariableStore_bindAndLookup() async {
        let store = VariableStore()
        await store.bind(name: "url", value: "https://plaud.ai/dashboard")
        let v = await store.lookup(name: "url")
        XCTAssertEqual(v, "https://plaud.ai/dashboard")
    }

    func testVariableStore_substitution() async throws {
        let store = VariableStore()
        await store.bind(name: "url", value: "https://example.com")
        await store.bind(name: "title", value: "Home")
        let result = try await store.substitute("Page at $url has title $title")
        XCTAssertEqual(result, "Page at https://example.com has title Home")
    }

    func testVariableStore_undefinedReferenceThrows() async {
        let store = VariableStore()
        do {
            _ = try await store.substitute("Hello $unset")
            XCTFail("expected undefinedVariable error")
        } catch let err as ScriptDispatchError {
            XCTAssertEqual(err.code, "undefinedVariable")
            XCTAssertTrue(err.message.contains("unset"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testVariableStore_escapedDollarPassesThrough() async throws {
        let store = VariableStore()
        await store.bind(name: "ignored", value: "X")
        let result = try await store.substitute("price: \\$10")
        XCTAssertEqual(result, "price: $10")
    }

    func testVariableStore_unmatchedDollarLeftIntact() async throws {
        // `$1`, `$%`, `$ ` (followed by non-identifier) are all left
        // verbatim — not every dollar sign is a substitution attempt.
        let store = VariableStore()
        let result = try await store.substitute("argv[$1] equals $% raw")
        XCTAssertEqual(result, "argv[$1] equals $% raw")
    }

    func testVariableStore_existsForBoundEmptyIsFalse() async {
        let store = VariableStore()
        await store.bind(name: "empty", value: "")
        let exists = await store.contains(name: "empty")
        XCTAssertFalse(exists)
    }

    func testVariableStore_existsForBoundNonEmpty() async {
        let store = VariableStore()
        await store.bind(name: "x", value: "value")
        let exists = await store.contains(name: "x")
        XCTAssertTrue(exists)
    }

    // MARK: - Expression evaluator

    func testEvaluator_containsTrue() async throws {
        let store = VariableStore()
        await store.bind(name: "url", value: "https://plaud.ai/dashboard")
        let result = try await ExpressionEvaluator.evaluate("$url contains \"plaud\"", store: store)
        XCTAssertTrue(result)
    }

    func testEvaluator_containsFalse() async throws {
        let store = VariableStore()
        await store.bind(name: "url", value: "https://example.com")
        let result = try await ExpressionEvaluator.evaluate("$url contains \"plaud\"", store: store)
        XCTAssertFalse(result)
    }

    func testEvaluator_equalsTrue() async throws {
        let store = VariableStore()
        await store.bind(name: "title", value: "Dashboard")
        let result = try await ExpressionEvaluator.evaluate("$title equals \"Dashboard\"", store: store)
        XCTAssertTrue(result)
    }

    func testEvaluator_equalsFalse() async throws {
        let store = VariableStore()
        await store.bind(name: "title", value: "dashboard")  // case differs
        let result = try await ExpressionEvaluator.evaluate("$title equals \"Dashboard\"", store: store)
        XCTAssertFalse(result)
    }

    func testEvaluator_existsTrue() async throws {
        let store = VariableStore()
        await store.bind(name: "token", value: "abc123")
        let result = try await ExpressionEvaluator.evaluate("$token exists", store: store)
        XCTAssertTrue(result)
    }

    func testEvaluator_existsFalseWhenUnbound() async throws {
        let store = VariableStore()
        let result = try await ExpressionEvaluator.evaluate("$missing exists", store: store)
        XCTAssertFalse(result)
    }

    func testEvaluator_rejectsAndCombinator() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("$a contains \"x\" and $a contains \"x\"", store: store)
    }

    func testEvaluator_rejectsOrCombinator() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("$a contains \"x\" or $a contains \"y\"", store: store)
    }

    func testEvaluator_rejectsParens() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("($a contains \"x\")", store: store)
    }

    func testEvaluator_rejectsNotPrefix() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("not $a contains \"x\"", store: store)
    }

    func testEvaluator_rejectsUnknownOperator() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("$a startsWith \"x\"", store: store)
    }

    func testEvaluator_rejectsMalformedExpression() async {
        let store = VariableStore()
        await assertEvaluatorThrows("nonsense", store: store)
    }

    func testEvaluator_rejectsUnquotedLiteral() async {
        let store = VariableStore()
        await store.bind(name: "a", value: "x")
        await assertEvaluatorThrows("$a contains x", store: store)
    }

    private func assertEvaluatorThrows(
        _ expression: String,
        store: VariableStore,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        do {
            _ = try await ExpressionEvaluator.evaluate(expression, store: store)
            XCTFail("expected evaluator to throw for: \(expression)", file: file, line: line)
        } catch let err as ScriptDispatchError {
            XCTAssertEqual(err.code, "invalidCondition", file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - StepResult JSON

    func testStepResult_okEncoding() {
        let r = StepResult.ok(step: 0, value: "https://x", varName: "u")
        let json = StepResult.encodeArray([r])
        XCTAssertTrue(json.contains("\"status\" : \"ok\""))
        XCTAssertTrue(json.contains("\"value\" : \"https:\\/\\/x\""))
        XCTAssertTrue(json.contains("\"var\" : \"u\""))
        XCTAssertFalse(json.contains("\"error\""))
        XCTAssertFalse(json.contains("\"reason\""))
    }

    func testStepResult_skippedEncoding() {
        let r = StepResult.skipped(step: 1, reason: "if:false")
        let json = StepResult.encodeArray([r])
        XCTAssertTrue(json.contains("\"status\" : \"skipped\""))
        XCTAssertTrue(json.contains("\"reason\" : \"if:false\""))
        XCTAssertFalse(json.contains("\"value\""))
    }

    func testStepResult_errorEncoding() {
        let r = StepResult.error(step: 2, code: "elementNotFound", message: "missing")
        let json = StepResult.encodeArray([r])
        XCTAssertTrue(json.contains("\"status\" : \"error\""))
        XCTAssertTrue(json.contains("\"code\" : \"elementNotFound\""))
        XCTAssertTrue(json.contains("\"message\" : \"missing\""))
    }

    func testStepResult_emptyArrayEncoded() {
        let json = StepResult.encodeArray([])
        XCTAssertTrue(
            json.trimmingCharacters(in: .whitespacesAndNewlines) == "[]",
            "expected empty JSON array, got '\(json)'"
        )
    }
}
