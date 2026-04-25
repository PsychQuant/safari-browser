import Foundation

/// Section 3 of `daemon-security-hardening` — log-formatting helpers that
/// satisfy `Requirement: Daemon log redaction` from the persistent-daemon
/// spec. The functions here are pure: they consume / emit `Data` (or
/// strings) and never touch the filesystem. Wiring into the actual log
/// file is the caller's responsibility — typically `DaemonServer.dispatchLine`
/// pipes redacted strings through an injected writer closure.
///
/// The four-rule contract this module enforces:
///
/// 1. `params.source` (for `applescript.execute`) and `params.code`
///    (for prospective `Safari.js` family) SHALL be replaced with the
///    literal string `<redacted N bytes>` where N is the original byte
///    length. Raw payload SHALL NEVER appear in the log.
/// 2. Result string fields longer than 256 bytes SHALL be truncated to
///    256 bytes with a trailing `…(truncated)` marker. Short strings
///    (≤ 256 bytes) — including error metadata — pass through unchanged
///    so debugging stays effective.
/// 3. Method name, requestId, timestamp, duration, error code SHALL
///    NEVER be redacted because they are the primary debugging surface.
/// 4. `SAFARI_BROWSER_DAEMON_LOG_FULL=1` MAY disable redaction entirely
///    for local-debugging sessions; the daemon SHALL emit a single
///    stderr warning at startup when that opt-out is active.
enum DaemonLog {
    /// Per-spec truncation cap. Public so tests can assert on the value.
    static let truncationLimit = 256

    /// The opt-out env variable name. Hardcoded — no wildcard / alias.
    static let logFullEnvVar = "SAFARI_BROWSER_DAEMON_LOG_FULL"

    // MARK: - Redaction

    /// Methods that carry user-supplied AppleScript / JS source in params.
    /// Each entry maps method-name → list of param keys whose values
    /// SHALL be redacted. The list of keys is intentionally short:
    /// adding a new sensitive method here is the gate any future
    /// contributor must pass through.
    private static let sensitiveParamKeys: [String: [String]] = [
        "applescript.execute": ["source"],
        // Defensive: future Safari.js family. The exact method name
        // hasn't shipped yet, but redaction is keyed on key-name
        // anyway so any method whose params include `code` gets
        // covered without spec drift.
        "Safari.js": ["code"],
        "Safari.js.code": ["code"],
    ]

    /// All keys that trigger redaction regardless of method. Defensive
    /// belt — if a future caller forgets to register the method in the
    /// table above, the key-based fallback still scrubs the payload.
    private static let unconditionallySensitiveKeys: Set<String> = ["source", "code"]

    /// Return a logger-safe rendering of the params payload. When
    /// `logFull` is true, the input is returned unchanged (operator
    /// opt-out). When false, sensitive fields are replaced with the
    /// `<redacted N bytes>` placeholder. Malformed JSON produces a
    /// safe placeholder rather than leaking the raw bytes.
    static func redactParams(method: String, paramsJSON: Data, logFull: Bool) -> Data {
        if logFull { return paramsJSON }

        // Parse first; if it's not a JSON object we cannot redact
        // structurally, so emit a safe placeholder.
        guard let parsed = try? JSONSerialization.jsonObject(with: paramsJSON, options: [.fragmentsAllowed]),
              var dict = parsed as? [String: Any] else {
            let placeholder: [String: Any] = [
                "_log": "<redacted \(paramsJSON.count) bytes; malformed params>",
            ]
            return (try? JSONSerialization.data(withJSONObject: placeholder, options: []))
                ?? Data(#"{"_log":"<redacted; serialization failed>"}"#.utf8)
        }

        let methodKeys = sensitiveParamKeys[method] ?? []
        let keysToRedact = Set(methodKeys).union(unconditionallySensitiveKeys)

        for key in keysToRedact {
            if let value = dict[key] as? String {
                dict[key] = "<redacted \(value.utf8.count) bytes>"
            }
        }

        return (try? JSONSerialization.data(withJSONObject: dict, options: []))
            ?? Data(#"{"_log":"<redacted; serialization failed>"}"#.utf8)
    }

    // MARK: - Truncation

    /// Return a logger-safe rendering of the result payload. When
    /// `logFull` is true, the input is returned unchanged. When false,
    /// every string value longer than `truncationLimit` bytes is
    /// truncated with a trailing `…(truncated)` marker. Short strings
    /// — including error messages — pass through unchanged.
    static func truncateResult(resultJSON: Data, logFull: Bool) -> Data {
        if logFull { return resultJSON }

        guard let parsed = try? JSONSerialization.jsonObject(with: resultJSON, options: [.fragmentsAllowed]) else {
            return resultJSON
        }

        let truncated = truncateAny(parsed)
        return (try? JSONSerialization.data(withJSONObject: truncated, options: [.fragmentsAllowed]))
            ?? resultJSON
    }

    /// Recursive helper: walks dicts / arrays, truncates long strings.
    /// Non-string scalars (numbers, bool, null) pass through.
    private static func truncateAny(_ value: Any) -> Any {
        if let s = value as? String {
            return truncateString(s)
        }
        if let arr = value as? [Any] {
            return arr.map(truncateAny)
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = truncateAny(v)
            }
            return out
        }
        return value
    }

    /// UTF-8-safe truncation. Returns the original string when its byte
    /// length is at or below `truncationLimit`. Otherwise, slices the
    /// underlying UTF-8 bytes at a valid character boundary at or below
    /// the cap and appends the truncation marker.
    private static func truncateString(_ s: String) -> String {
        let bytes = Array(s.utf8)
        if bytes.count <= truncationLimit { return s }
        // Walk back from the cap to a UTF-8 leading-byte position so we
        // never split a multi-byte sequence. Continuation bytes have the
        // top two bits as `10`; leading bytes for ASCII or multi-byte
        // sequences do not.
        var cut = truncationLimit
        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 {
            cut -= 1
        }
        let prefix = Array(bytes[0..<cut])
        let prefixString = String(decoding: prefix, as: UTF8.self)
        return prefixString + "…(truncated)"
    }

    // MARK: - Opt-out

    /// Pure decision: is `SAFARI_BROWSER_DAEMON_LOG_FULL` set to literal
    /// `"1"`? Other truthy strings (`"true"`, `"yes"`) do NOT enable —
    /// matching the spec's exact-value wording and avoiding accidental
    /// bypass via shell scripts that pass arbitrary truthy values.
    static func isFullLoggingEnabled(env: [String: String]) -> Bool {
        env[logFullEnvVar] == "1"
    }

    /// If `LOG_FULL=1`, write a single warning line through `writer`
    /// (typically `FileHandle.standardError.write`). Otherwise no-op.
    /// Idempotent at the call-site level: callers SHOULD invoke once
    /// at daemon startup; calling twice prints twice.
    static func emitFullLogWarningIfNeeded(env: [String: String], writer: (String) -> Void) {
        guard isFullLoggingEnabled(env: env) else { return }
        writer("[daemon] WARNING: \(logFullEnvVar)=1 — logs contain raw AppleScript and JS source\n")
    }

    // MARK: - Format

    /// Compose a single log entry as a stable JSON-line. Every field
    /// goes in the same shape so `jq`-driven grep over the daemon log
    /// stays straightforward.
    ///
    /// Schema:
    /// ```
    /// {"ts":"<ISO8601>","method":"...","requestId":<any>,"durationMs":<int>,
    ///  "params":<redacted JSON or null>,"result":<truncated JSON or null>,
    ///  "error":"<message or null>"}
    /// ```
    static func formatEntry(
        timestamp: Date,
        method: String,
        requestId: Any?,
        durationMs: Int,
        paramsLog: String,
        resultLog: String?,
        errorLog: String?
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Re-parse the redacted params/result strings so they appear
        // as nested JSON in the log line, not as escaped string blobs.
        let paramsAny: Any = (try? JSONSerialization.jsonObject(
            with: Data(paramsLog.utf8), options: [.fragmentsAllowed]
        )) ?? paramsLog

        let resultAny: Any = {
            guard let r = resultLog else { return NSNull() }
            return (try? JSONSerialization.jsonObject(
                with: Data(r.utf8), options: [.fragmentsAllowed]
            )) ?? r
        }()

        let envelope: [String: Any] = [
            "ts": formatter.string(from: timestamp),
            "method": method,
            "requestId": requestId ?? NSNull(),
            "durationMs": durationMs,
            "params": paramsAny,
            "result": resultAny,
            "error": errorLog ?? NSNull(),
        ]

        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: []))
            ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}
