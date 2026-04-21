import Foundation

/// Task 5.1 / 5.2 — opt-in detection and silent-fallback router that sits
/// between individual SafariBridge operations and the low-level stateless
/// AppleScript path. This file adds extensions to `SafariBridge`; it does
/// NOT yet wire them into any command. Command routing lands in task 7.1.
///
/// The router is intentionally dependency-injected (daemonFn / statelessFn
/// are closures) so it can be tested without a real daemon or Safari.

extension SafariBridge {

    /// Three-signal opt-in detection per the `Daemon mode is opt-in` spec
    /// requirement. Any one of (flag / env / live socket) returns `true`.
    /// The default (all three false) preserves the stateless CLI contract.
    ///
    /// - Parameters:
    ///   - flag: the `--daemon` CLI flag value from the command invocation.
    ///   - env: process environment (defaults to `ProcessInfo`). `SAFARI_BROWSER_DAEMON`
    ///     must equal literal `"1"` to count — other truthy strings do not,
    ///     matching the spec's "set to 1" wording.
    ///   - socketExists: injectable for tests; in production this is
    ///     `FileManager.default.fileExists(atPath:)`. The path checked is
    ///     derived from `DaemonClient.resolveName(flag:env:)` and
    ///     `DaemonClient.socketPath(name:)`, so NAME namespace isolation
    ///     extends to detection — a socket for NAME `beta` does not opt in
    ///     an invocation that resolves to NAME `alpha`.
    static func shouldUseDaemon(
        flag: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment,
        socketExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if flag { return true }
        if env["SAFARI_BROWSER_DAEMON"] == "1" { return true }
        let name = DaemonClient.resolveName(flag: nil, env: env)
        let path = DaemonClient.socketPath(name: name)
        if socketExists(path) { return true }
        return false
    }

    /// Silent-fallback router. When `daemonOptIn` is false, behaves exactly
    /// like `statelessFn` — zero-overhead passthrough. When `daemonOptIn` is
    /// true, tries `daemonFn` first; on a fallback-worthy `DaemonClient.Error`
    /// emits a single-line `[daemon fallback: <reason>]` warning via
    /// `warnWriter` and retries through `statelessFn`. Safari domain errors
    /// (e.g. `ambiguousWindowMatch`) propagate without fallback because they
    /// would produce the same result via the stateless path anyway.
    ///
    /// Non-`DaemonClient.Error` throws propagate as-is — the router assumes
    /// arbitrary Swift errors from `daemonFn` represent programmer bugs, not
    /// daemon failures, and should not silently retry.
    static func runViaRouter(
        source: String,
        daemonOptIn: Bool,
        daemonFn: (String) async throws -> String,
        statelessFn: (String) async throws -> String,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        guard daemonOptIn else {
            return try await statelessFn(source)
        }
        do {
            return try await daemonFn(source)
        } catch let err as DaemonClient.Error {
            guard let reason = err.fallbackReason else {
                // Domain error: propagate untouched.
                throw err
            }
            warnWriter?("[daemon fallback: \(reason)]\n")
            return try await statelessFn(source)
        }
    }
}
