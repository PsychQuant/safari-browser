import Foundation

/// Top-level executor for `safari-browser exec` scripts. Coordinates the
/// parser, variable store, expression evaluator, and command dispatcher
/// per the script-exec capability spec.
struct ScriptInterpreter {
    static let defaultMaxSteps: Int = 1000

    let maxSteps: Int
    let dispatcher: any StepDispatcher

    init(
        maxSteps: Int = ScriptInterpreter.defaultMaxSteps,
        dispatcher: any StepDispatcher = SubprocessStepDispatcher()
    ) {
        self.maxSteps = maxSteps
        self.dispatcher = dispatcher
    }

    /// Parses and executes a script document. Returns the result array
    /// for the caller to encode and emit. Parse-time errors throw
    /// `ScriptParseError`; per-step runtime errors are recorded inline
    /// in the returned result array per `onError` semantics.
    func run(source: String, target: TargetOptions) async throws -> [StepResult] {
        let steps = try Self.parseScript(source: source, maxSteps: maxSteps)
        return try await runSteps(steps, target: target)
    }

    /// Run an already-parsed step list. Used by the daemon
    /// `exec.runScript` handler which receives steps as JSON objects
    /// already validated against `ScriptStep`.
    func runSteps(_ steps: [ScriptStep], target: TargetOptions) async throws -> [StepResult] {
        let sharedTargetArgs = Self.encodeTargetArgs(target)
        let store = VariableStore()

        var results: [StepResult] = []
        results.reserveCapacity(steps.count)

        for (index, step) in steps.enumerated() {
            // Evaluate `if:` first — skipped steps never substitute or run.
            if let condition = step.ifExpression {
                do {
                    let pass = try await ExpressionEvaluator.evaluate(condition, store: store)
                    if !pass {
                        results.append(.skipped(step: index, reason: "if:false"))
                        continue
                    }
                } catch let err as ScriptDispatchError {
                    results.append(.error(step: index, code: err.code, message: err.message))
                    if step.onError == .abort { break }
                    continue
                }
            }

            // Substitute `$var` references in args before dispatch.
            let substitutedArgs: [String]
            do {
                var collected: [String] = []
                collected.reserveCapacity(step.args.count)
                for arg in step.args {
                    collected.append(try await store.substitute(arg))
                }
                substitutedArgs = collected
            } catch let err as ScriptDispatchError {
                results.append(.error(step: index, code: err.code, message: err.message))
                if step.onError == .abort { break }
                continue
            }

            // Dispatch and bind the result.
            do {
                let value = try await dispatcher.dispatch(
                    cmd: step.cmd,
                    args: substitutedArgs,
                    sharedTargetArgs: sharedTargetArgs
                )
                if let varName = step.varName {
                    await store.bind(name: varName, value: value)
                }
                results.append(.ok(step: index, value: value, varName: step.varName))
            } catch let err as ScriptDispatchError {
                results.append(.error(step: index, code: err.code, message: err.message))
                if step.onError == .abort { break }
            } catch let err as SafariBrowserError {
                let code = Self.errorCode(for: err)
                results.append(.error(
                    step: index,
                    code: code,
                    message: err.errorDescription ?? "\(err)"
                ))
                if step.onError == .abort { break }
            } catch {
                results.append(.error(
                    step: index,
                    code: "internalError",
                    message: "\(error)"
                ))
                if step.onError == .abort { break }
            }
        }

        return results
    }

    /// Maps a `SafariBrowserError` case to a stable string code for the
    /// result array. The set is intentionally narrow — we only enumerate
    /// the cases that meaningfully reach an exec script. Everything else
    /// degrades to `appleScriptFailed`.
    private static func errorCode(for err: SafariBrowserError) -> String {
        switch err {
        case .fileNotFound: return "fileNotFound"
        case .documentNotFound: return "documentNotFound"
        case .ambiguousWindowMatch: return "ambiguousWindowMatch"
        case .elementNotFound: return "elementNotFound"
        case .timeout, .processTimedOut: return "timeout"
        default: return "appleScriptFailed"
        }
    }

    /// Parses raw JSON source into a list of `ScriptStep` values, applying
    /// the max-steps cap. Throws `ScriptParseError` on any structural
    /// problem so the caller can surface the error before any step runs.
    static func parseScript(source: String, maxSteps: Int) throws -> [ScriptStep] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptParseError.invalidScriptFormat("empty script input")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ScriptParseError.invalidScriptFormat("source is not UTF-8")
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ScriptParseError.invalidScriptFormat("not valid JSON: \(error.localizedDescription)")
        }

        guard let arr = raw as? [Any] else {
            throw ScriptParseError.invalidScriptFormat("script root must be a JSON array")
        }
        if arr.count > maxSteps {
            throw ScriptParseError.maxStepsExceeded(actual: arr.count, cap: maxSteps)
        }

        var steps: [ScriptStep] = []
        steps.reserveCapacity(arr.count)
        for (index, raw) in arr.enumerated() {
            guard let obj = raw as? [String: Any] else {
                throw ScriptParseError.invalidStepSchema("step \(index): must be a JSON object")
            }
            // Re-encode → Decode through ScriptStep's strict Decodable to
            // benefit from the unknown-key rejection logic, while keeping
            // the index in the error message for human readability.
            do {
                let stepData = try JSONSerialization.data(withJSONObject: obj, options: [])
                let decoder = JSONDecoder()
                let step = try decoder.decode(ScriptStep.self, from: stepData)
                steps.append(step)
            } catch let err as ScriptParseError {
                let msg = err.message
                throw ScriptParseError.invalidStepSchema("step \(index): \(msg)")
            } catch {
                throw ScriptParseError.invalidStepSchema("step \(index): \(error.localizedDescription)")
            }
        }
        return steps
    }

    /// Reconstructs the CLI flags for the exec-level target so subprocess
    /// dispatch can pass them to each step that doesn't override.
    static func encodeTargetArgs(_ options: TargetOptions) -> [String] {
        var out: [String] = []
        if let url = options.url { out.append(contentsOf: ["--url", url]) }
        if let urlExact = options.urlExact { out.append(contentsOf: ["--url-exact", urlExact]) }
        if let urlEndswith = options.urlEndswith { out.append(contentsOf: ["--url-endswith", urlEndswith]) }
        if let urlRegex = options.urlRegex { out.append(contentsOf: ["--url-regex", urlRegex]) }
        if let window = options.window { out.append(contentsOf: ["--window", String(window)]) }
        if let tab = options.tab { out.append(contentsOf: ["--tab", String(tab)]) }
        if let document = options.document { out.append(contentsOf: ["--document", String(document)]) }
        if let tabInWindow = options.tabInWindow {
            out.append(contentsOf: ["--tab-in-window", String(tabInWindow)])
        }
        if options.firstMatch { out.append("--first-match") }
        return out
    }
}
