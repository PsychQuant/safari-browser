import Foundation

/// Per-step result entry emitted in the final result array per
/// Requirement: Exec emits a structured result array.
struct StepResult: Equatable {
    enum Status: String, Equatable {
        case ok
        case error
        case skipped
    }

    let step: Int
    let status: Status
    let value: String?
    let varName: String?
    let reason: String?
    let errorCode: String?
    let errorMessage: String?

    static func ok(step: Int, value: String, varName: String?) -> StepResult {
        StepResult(
            step: step, status: .ok, value: value, varName: varName,
            reason: nil, errorCode: nil, errorMessage: nil
        )
    }

    static func skipped(step: Int, reason: String) -> StepResult {
        StepResult(
            step: step, status: .skipped, value: nil, varName: nil,
            reason: reason, errorCode: nil, errorMessage: nil
        )
    }

    static func error(step: Int, code: String, message: String) -> StepResult {
        StepResult(
            step: step, status: .error, value: nil, varName: nil,
            reason: nil, errorCode: code, errorMessage: message
        )
    }

    private func encodableObject() -> [String: Any] {
        var dict: [String: Any] = [
            "step": step,
            "status": status.rawValue,
        ]
        if let value { dict["value"] = value }
        if let varName { dict["var"] = varName }
        if let reason { dict["reason"] = reason }
        if let errorCode, let errorMessage {
            dict["error"] = ["code": errorCode, "message": errorMessage]
        }
        return dict
    }

    static func encodeArray(_ results: [StepResult]) -> String {
        if results.isEmpty { return "[]" }
        let arr = results.map { $0.encodableObject() }
        guard let data = try? JSONSerialization.data(
            withJSONObject: arr,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
