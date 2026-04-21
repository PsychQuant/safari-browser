import Foundation

/// Wire-format constants shared by `DaemonServer` and `DaemonClient`.
///
/// Task 6.3: the daemon emits a handshake line as the FIRST message on
/// every new connection. The client reads that line, verifies the
/// `version` matches the client's build, and only then sends requests.
/// A mismatch triggers the `Silent fallback to stateless path on daemon
/// failure` path via a `remoteError(code: "versionMismatch", ...)` that
/// `DaemonClient.Error.fallbackReason` classifies as fallback-worthy.
enum DaemonProtocol {
    /// Current wire-format version. Bump when the request/response shape
    /// changes in a way that old clients cannot understand. Patch-level
    /// changes inside `params` / `result` payloads do NOT require a bump
    /// as long as existing fields keep their meaning.
    static let currentVersion = "1.0.0"

    /// Handshake envelope the server writes as the first line after
    /// accepting a connection. The client reads one line and decodes it
    /// via `decodeHandshake`.
    static func encodeHandshake(version: String = currentVersion) -> Data {
        let envelope: [String: Any] = [
            "protocol": [
                "name": "persistent-daemon",
                "version": version,
            ] as [String: Any]
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
    }

    /// Parse a handshake line. Returns the `version` string on success,
    /// nil if the line does not look like a handshake at all.
    static func decodeHandshakeVersion(_ line: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
            let proto = obj["protocol"] as? [String: Any],
            let version = proto["version"] as? String
        else {
            return nil
        }
        return version
    }
}
