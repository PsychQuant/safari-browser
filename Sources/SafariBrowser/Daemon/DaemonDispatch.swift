import Foundation

/// Wires registered DaemonServer method handlers to `PreCompiledScripts.CompileCache`.
///
/// This file implements task 4.1: the bridge layer that lets DaemonServer
/// method dispatch serve Safari-bound work via pre-compiled script handles.
///
/// Task 4.1 deliverable is limited to Safari-free demonstration handlers
/// (`cache.arithmetic`). The Phase 1 Safari handlers (`safari.enumerateWindows`,
/// `safari.activateWindow`, `safari.runJSInCurrentTab`, etc.) land in task 7.1
/// where command routing switches to the daemon path. Registering them here
/// is premature because the command-side wiring does not yet exist.
///
/// All handlers route execution through `PreCompiledScripts.CompileCache`,
/// which is an actor — that is how the `No Safari state cache` / Path A
/// requirement and the "single-consumer serialization of AppleScript calls"
/// design decision are enforced simultaneously. Handlers MUST NOT retain any
/// Safari-side state between invocations; the only cache is the compiled
/// `NSAppleScript` handle, keyed by source text.
enum DaemonDispatch {

    /// Register the Safari-free demonstration handlers used by unit tests to
    /// prove the dispatch wiring without requiring a running Safari. Call
    /// once during daemon startup; calling twice overwrites the previous
    /// registration for each method.
    static func registerDemoHandlers(
        on server: DaemonServer.Instance,
        cache: PreCompiledScripts.CompileCache
    ) async {
        await server.register("cache.arithmetic") { [cache] params in
            try await Handlers.cacheArithmetic(paramsData: params, cache: cache)
        }
    }

    /// Register the Phase 1 handlers the production daemon needs in addition
    /// to the demo handlers. Task 7.1 routes `SafariBridge.runAppleScript`
    /// through `applescript.execute`, so all eleven Phase 1 commands
    /// (`snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`,
    /// `get url`, `get title`, `wait`, `storage`) inherit daemon
    /// acceleration transparently via the router layer.
    static func registerPhase1Handlers(
        on server: DaemonServer.Instance,
        cache: PreCompiledScripts.CompileCache
    ) async {
        await registerDemoHandlers(on: server, cache: cache)
        await server.register("applescript.execute") { [cache] params in
            try await Handlers.appleScriptExecute(paramsData: params, cache: cache)
        }
        // Section 10 v2 of `script-exec-command`: connection-shared
        // execution. The client sends a single `exec.runScript` request
        // carrying steps + target + maxSteps; the daemon runs the
        // interpreter in-process and returns the result array. Eliminates
        // per-step subprocess + socket handshake from the client path.
        await server.register("exec.runScript") { params in
            try await Handlers.execRunScript(paramsData: params)
        }
    }

    /// Errors raised by `exec.runScript` for envelope-level problems.
    /// Per-step errors are recorded inside the returned result array;
    /// these only fire for malformed envelopes that the daemon cannot
    /// recover from.
    enum ExecRunScriptError: Error, CustomStringConvertible {
        case malformedEnvelope(String)
        case parseError(String, String)

        var description: String {
            switch self {
            case .malformedEnvelope(let reason): return "exec.runScript envelope: \(reason)"
            case .parseError(let code, let msg): return "exec.runScript parse [\(code)]: \(msg)"
            }
        }
    }

    /// Concrete handler implementations. Factored out so each handler can be
    /// unit-tested in isolation from the socket layer.
    enum Handlers {
        /// `cache.arithmetic({"expression": "<AppleScript numeric expr>"})`
        ///
        /// Builds `return <expression>` as AppleScript, routes through the
        /// shared CompileCache, and returns the `int32` result. Cached by
        /// source string — repeated calls with the same expression do not
        /// grow the cache beyond one entry (Path A verification).
        static func cacheArithmetic(
            paramsData: Data,
            cache: PreCompiledScripts.CompileCache
        ) async throws -> Data {
            struct Params: Decodable { let expression: String }
            let params = try JSONDecoder().decode(Params.self, from: paramsData)
            let source = "return \(params.expression)"
            let result = try await cache.execute(source: source)
            let response: [String: Any] = ["int32": Int(result.int32Value)]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }

        /// `applescript.execute({"source": "<AppleScript source>"})`
        ///
        /// Compiles (cached) + executes the source via the shared CompileCache,
        /// mirroring what the stateless `osascript -e ...` subprocess does.
        /// Returns a structured payload so AppleScript compile/execute errors
        /// propagate to the client without being mislabelled as protocol or
        /// transport failures (which would trigger fallback — AppleScript
        /// errors are Safari-domain and must surface directly).
        ///
        /// Response shape:
        /// - `{"status":"ok","output":"<stringValue>"}` on success
        /// - `{"status":"error","errorKind":"compileFailed","message":"..."}`
        ///   when NSAppleScript rejects the source
        /// - `{"status":"error","errorKind":"executeFailed","message":"..."}`
        ///   when the script throws at runtime
        /// `exec.runScript({"steps":[...],"target":{...},"maxSteps":N})`
        ///
        /// Runs the supplied script through `ScriptInterpreter` with
        /// `InProcessStepDispatcher` so each step routes directly to
        /// `SafariBridge` rather than spawning a subprocess. Returns the
        /// result array under `{"results": [...]}`. Errors at the parse
        /// or per-step level are surfaced inline in the result array
        /// per the script-exec spec; only structural errors (malformed
        /// envelope, undecodable target, maxSteps overflow) raise as
        /// thrown errors that the dispatcher maps to `handlerError`.
        static func execRunScript(paramsData: Data) async throws -> Data {
            // Decode envelope: steps, target (TargetOptions JSON), maxSteps,
            // optional markTab (Section 7 of tab-ownership-marker v2 — when
            // non-off, wrap the entire script execution with a marker so
            // multi-step daemon requests carry one request-spanning lock
            // instead of N per-step toggles).
            guard let envelope = try? JSONSerialization.jsonObject(with: paramsData, options: []) as? [String: Any] else {
                throw ExecRunScriptError.malformedEnvelope("not a JSON object")
            }
            guard let steps = envelope["steps"] as? [[String: Any]] else {
                throw ExecRunScriptError.malformedEnvelope("missing or invalid 'steps' array")
            }
            let targetArgs = (envelope["targetArgs"] as? [String]) ?? []
            let maxSteps = (envelope["maxSteps"] as? Int) ?? ScriptInterpreter.defaultMaxSteps
            let markTabRaw = (envelope["markTab"] as? String) ?? "off"
            guard let markTabMode = TargetOptions.MarkTabMode(rawValue: markTabRaw) else {
                throw ExecRunScriptError.malformedEnvelope(
                    "invalid markTab value '\(markTabRaw)' (expected 'off' / 'ephemeral' / 'persist')"
                )
            }

            let target: TargetOptions
            do {
                target = try TargetOptions.parse(targetArgs)
            } catch {
                throw ExecRunScriptError.malformedEnvelope("could not parse targetArgs: \(error)")
            }

            // Re-encode steps to JSON string so we can re-parse through the
            // strict decoder, then run via the in-process dispatcher.
            let stepsData = try JSONSerialization.data(withJSONObject: steps, options: [])
            guard let stepsJSON = String(data: stepsData, encoding: .utf8) else {
                throw ExecRunScriptError.malformedEnvelope("steps could not be re-encoded as UTF-8")
            }
            let parsedSteps: [ScriptStep]
            do {
                parsedSteps = try ScriptInterpreter.parseScript(source: stepsJSON, maxSteps: maxSteps)
            } catch let parse as ScriptParseError {
                throw ExecRunScriptError.parseError(parse.code, parse.message)
            } catch {
                throw ExecRunScriptError.parseError("invalidScriptFormat", "\(error)")
            }

            let interpreter = ScriptInterpreter(
                maxSteps: maxSteps,
                dispatcher: InProcessStepDispatcher()
            )

            // Section 7 of tab-ownership-marker v2: wrap the ENTIRE script
            // execution in `SafariBridge.markTabIfRequested` when the
            // request opts in. The wrapper takes care of wrap-before /
            // unwrap-after / title-race-on-cleanup; it does NOT toggle per
            // step (Requirement 7.3 — marker is owned by the request-actor
            // wrapper, not by individual steps). For `.off` the closure
            // body runs directly, so the daemon path stays zero-overhead
            // when no marker is requested.
            let resolved = try target.resolve()
            let results: [StepResult] = try await SafariBridge.markTabIfRequested(
                target: resolved,
                mode: markTabMode,
                firstMatch: target.firstMatch
            ) {
                try await interpreter.runSteps(parsedSteps, target: target)
            }

            // Encode the results array back as JSON. `StepResult.encodeArray`
            // produces the same format as the stateless command's stdout.
            let jsonString = StepResult.encodeArray(results)
            let payload: [String: Any] = ["results": jsonString]
            return try JSONSerialization.data(withJSONObject: payload, options: [])
        }

        static func appleScriptExecute(
            paramsData: Data,
            cache: PreCompiledScripts.CompileCache
        ) async throws -> Data {
            struct Params: Decodable { let source: String }
            let params = try JSONDecoder().decode(Params.self, from: paramsData)
            do {
                let result = try await cache.execute(source: params.source)
                let response: [String: Any] = [
                    "status": "ok",
                    "output": result.stringValue ?? "",
                ]
                return try JSONSerialization.data(withJSONObject: response, options: [])
            } catch PreCompiledScripts.Error.compilationFailed(let msg) {
                let response: [String: Any] = [
                    "status": "error",
                    "errorKind": "compileFailed",
                    "message": msg,
                ]
                return try JSONSerialization.data(withJSONObject: response, options: [])
            } catch PreCompiledScripts.Error.executionFailed(let msg) {
                let response: [String: Any] = [
                    "status": "error",
                    "errorKind": "executeFailed",
                    "message": msg,
                ]
                return try JSONSerialization.data(withJSONObject: response, options: [])
            }
        }
    }
}
