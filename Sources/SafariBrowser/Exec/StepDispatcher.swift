import Foundation

/// Section 10 v2 of `script-exec-command` — dispatcher abstraction so
/// `ScriptInterpreter` can route each step either through a subprocess
/// (the v1 default, used by stateless mode) or directly through
/// `SafariBridge` (the v2 daemon-side path that eliminates per-step
/// subprocess spawn cost while keeping a single client-daemon socket).
///
/// Implementations are intentionally minimal: receive a step's `cmd`
/// (e.g. `"get url"`), `args` (already substituted from `$var`), and
/// the exec-level `sharedTargetArgs` (fallback target when the step
/// does not override). Return the step's stdout-style result string.
/// Errors flow as Swift throws — `ScriptInterpreter` translates them
/// into `StepResult.error` with the appropriate code.
protocol StepDispatcher: Sendable {
    func dispatch(
        cmd: String,
        args: [String],
        sharedTargetArgs: [String]
    ) async throws -> String
}
