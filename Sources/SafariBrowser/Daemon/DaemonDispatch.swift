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
