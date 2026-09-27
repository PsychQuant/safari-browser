import Foundation

/// One page-side result lifetime. The nonce prevents accidental cross-call
/// reads; it is not an authentication boundary against scripts in that page.
struct JavaScriptResultSession {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var key: String { "__sbInvocation_" + token }
    private let chunkSize = 262_144

    enum TransferFailure: Error, CustomStringConvertible {
        case unavailable
        case preparationFailed
        case executionResultLost
        case runtimeErrorDetailsLost
        case malformed
        case invalidUTF16
        case outputUnavailableAfterNavigation
        var description: String {
            switch self {
            case .preparationFailed: return "Could not prepare fresh JavaScript result state; user code was not executed"
            case .runtimeErrorDetailsLost: return "JavaScript reported a runtime error but its details were lost; code was not retried"
            case .executionResultLost: return "JavaScript ran but its result state was lost; code was not retried"
            case .unavailable: return "JavaScript result state was lost or execution could not be confirmed; code was not retried"
            case .outputUnavailableAfterNavigation: return "JavaScript completed but navigated before a result could be saved; --output was left unchanged. The code was not retried."
            case .invalidUTF16: return "JavaScript result contains an unpaired UTF-16 surrogate and cannot be transferred losslessly"
            case .malformed: return "JavaScript result transfer was incomplete or belonged to another invocation"
            }
        }
    }

    private enum Phase: String { case prepared, running, done, error }

    var prepareScript: String {
        "(function(){window.\(key)={token:'\(token)',phase:'prepared',text:''};return '\(token):prepared';})()"
    }
    var cleanupScript: String { "delete window.\(key)" }

    private var metadataScript: String {
        """
        (function(){var s=window.\(key);if(!s||s.token!=='\(token)'||typeof s.text!=='string')return '';
        return '\(token):'+s.phase+':'+s.text.length;})()
        """
    }

    private func frameScript(offset: Int, end: Int, total: Int) -> String {
        """
        (function(){var s=window.\(key);if(!s||s.token!=='\(token)'||(s.phase!=='done'&&s.phase!=='error')||typeof s.text!=='string'||s.text.length!==\(total))return '';
        var text=s.text,end=\(end),start=\(offset);
        if(end<text.length){var a=text.charCodeAt(end-1),b=text.charCodeAt(end);if(a>=55296&&a<=56319&&b>=56320&&b<=57343)end--;}
        for(var i=start;i<end;i++){var c=text.charCodeAt(i);if(c>=55296&&c<=56319){if(i+1>=end)return '\(token):invalid-utf16';var d=text.charCodeAt(++i);if(d<56320||d>57343)return '\(token):invalid-utf16';}else if(c>=56320&&c<=57343)return '\(token):invalid-utf16';}
        return '\(token):\(offset):'+end+':'+text.substring(start,end)+':\(token)';})()
        """
    }

    private func decimal(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(value)
    }

    private func metadata(_ raw: String) throws -> (Phase, Int) {
        guard !raw.isEmpty else { throw TransferFailure.unavailable }
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == token,
              let phase = Phase(rawValue: String(fields[1])), let length = decimal(fields[2]) else {
            throw TransferFailure.malformed
        }
        return (phase, length)
    }

    private func evaluationReceipt(_ raw: String) throws -> Phase? {
        if raw.isEmpty { return nil } // Expression syntax failure has no receipt.
        if raw == "\(token):done" { return .done }
        if raw == "\(token):error" { return .error }
        throw TransferFailure.malformed
    }

    private func decodeFrame(_ raw: String, offset: Int, requestedEnd: Int) throws -> (String, Int) {
        if raw == "\(token):invalid-utf16" { throw TransferFailure.invalidUTF16 }
        // Parse ASCII framing as bytes. A payload-leading combining mark can
        // join the delimiter's grapheme cluster, so Character slicing is wrong.
        let bytes = Array(raw.utf8)
        let prefix = Array("\(token):\(offset):".utf8)
        let suffix = Array(":\(token)".utf8)
        guard bytes.starts(with: prefix), bytes.suffix(suffix.count).elementsEqual(suffix),
              bytes.count >= prefix.count + suffix.count else { throw TransferFailure.malformed }
        let middle = bytes[prefix.count..<(bytes.count - suffix.count)]
        guard let separator = middle.firstIndex(of: 58),
              let endText = String(bytes: middle[..<separator], encoding: .utf8),
              let end = decimal(endText[...]), end > offset, end <= requestedEnd, requestedEnd - end <= 1,
              let payload = String(bytes: middle[middle.index(after: separator)...], encoding: .utf8) else {
            throw TransferFailure.malformed
        }
        guard payload.utf16.count == end - offset else { throw TransferFailure.malformed }
        return (payload, end)
    }

    private func readResult(length: Int, chunked: Bool, evaluate: (String) async throws -> String) async throws -> String {
        if length == 0 { return "" }
        if !chunked {
            try Task.checkCancellation()
            let raw = try await evaluate(frameScript(offset: 0, end: length, total: length))
            try Task.checkCancellation()
            // Safari can return empty for a large reply. Re-read the captured
            // value in chunks, never the user's code. Nonempty bad frames fail.
            if !raw.isEmpty {
                let (text, end) = try decodeFrame(raw, offset: 0, requestedEnd: length)
                guard end == length else { throw TransferFailure.malformed }
                return text
            }
        }
        var result = ""
        var offset = 0
        while offset < length {
            try Task.checkCancellation()
            let end = offset + min(chunkSize, length - offset)
            let raw = try await evaluate(frameScript(offset: offset, end: end, total: length))
            try Task.checkCancellation()
            if raw.isEmpty {
                // A lost page is not a short payload. Re-observe owned state;
                // missing state can then reach receipt-gated navigation handling.
                _ = try metadata(await evaluate(metadataScript))
                throw TransferFailure.malformed
            }
            let (text, next) = try decodeFrame(raw, offset: offset, requestedEnd: end)
            result += text
            offset = next
        }
        guard result.utf16.count == length else { throw TransferFailure.malformed }
        return result
    }

    func execute(_ code: String, allowStatements: Bool, chunked: Bool,
                 evaluate: (String) async throws -> String) async throws -> String {
        try await DaemonRequestContext.$appleScriptCachePolicy.withValue(.ephemeral) {
            try await executeOwned(code, allowStatements: allowStatements, chunked: chunked, evaluate: evaluate)
        }
    }

    private func executeOwned(_ code: String, allowStatements: Bool, chunked: Bool,
                              evaluate: (String) async throws -> String) async throws -> String {
        try Task.checkCancellation()
        var evaluationPhase: Phase?
        do {
            guard try await evaluate(prepareScript) == "\(token):prepared" else { throw TransferFailure.preparationFailed }
            try Task.checkCancellation()
            evaluationPhase = try evaluationReceipt(await evaluate(JSWrapper.invocationWrapper(code, key: key, token: token, statement: false)))
            try Task.checkCancellation()
            var state = try metadata(await evaluate(metadataScript))
            try Task.checkCancellation()
            if let evaluationPhase, state.0 != evaluationPhase { throw TransferFailure.malformed }
            if state.0 == .prepared && allowStatements {
                evaluationPhase = try evaluationReceipt(await evaluate(JSWrapper.invocationWrapper(code, key: key, token: token, statement: true)))
                try Task.checkCancellation()
                state = try metadata(await evaluate(metadataScript))
                try Task.checkCancellation()
            }
            if let evaluationPhase, state.0 != evaluationPhase { throw TransferFailure.malformed }
            if state.0 == .prepared {
                throw SafariBrowserError.appleScriptFailed("JavaScript syntax error: the provided code did not parse in the supported expression or function-body form")
            }
            guard state.0 == .done || state.0 == .error else { throw TransferFailure.unavailable }
            evaluationPhase = state.0 // Fresh metadata independently confirms the outcome.
            let value = try await readResult(length: state.1, chunked: chunked, evaluate: evaluate)
            if state.0 == .error {
                throw SafariBrowserError.appleScriptFailed("JavaScript error: \(value)\(JSWrapper.cspEvalHint(for: value) ?? "")")
            }
            _ = try? await evaluate(cleanupScript)
            try Task.checkCancellation()
            return value
        } catch {
            _ = try? await evaluate(cleanupScript)
            try Task.checkCancellation()
            var stateLost = false
            if case TransferFailure.unavailable = error { stateLost = true }
            if let bridgeError = error as? SafariBrowserError {
                if case .targetTabChanged = bridgeError { stateLost = true }
                else if SafariBridge.isTargetDangleError(bridgeError) { stateLost = true }
            }
            // A receipt for an error is execution evidence, but never evidence
            // of successful navigation. Preserve failure even if its page is gone.
            if stateLost, evaluationPhase == .error { throw TransferFailure.runtimeErrorDetailsLost }
            if stateLost, evaluationPhase == .done { throw TransferFailure.executionResultLost }
            throw error
        }
    }
}
