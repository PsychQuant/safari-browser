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
        case malformed
        var description: String {
            switch self {
            case .preparationFailed: return "Could not prepare fresh JavaScript result state; user code was not executed"
            case .executionResultLost: return "JavaScript ran but its result state was lost; code was not retried"
            case .unavailable: return "JavaScript result state was lost or execution could not be confirmed; code was not retried"
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
        for(var i=start;i<end;i++){var c=text.charCodeAt(i);if(c>=55296&&c<=56319){if(i+1>=end)return '';var d=text.charCodeAt(++i);if(d<56320||d>57343)return '';}else if(c>=56320&&c<=57343)return '';}
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

    private func decodeFrame(_ raw: String, offset: Int, requestedEnd: Int) throws -> (String, Int) {
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
            let raw = try await evaluate(frameScript(offset: 0, end: length, total: length))
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
            let end = offset + min(chunkSize, length - offset)
            let raw = try await evaluate(frameScript(offset: offset, end: end, total: length))
            let (text, next) = try decodeFrame(raw, offset: offset, requestedEnd: end)
            result += text
            offset = next
        }
        guard result.utf16.count == length else { throw TransferFailure.malformed }
        return result
    }

    func execute(_ code: String, allowStatements: Bool, chunked: Bool,
                 evaluate: (String) async throws -> String) async throws -> String {
        var executionConfirmed = false
        do {
            guard try await evaluate(prepareScript) == "\(token):prepared" else { throw TransferFailure.preparationFailed }
            let expressionAck = try await evaluate(JSWrapper.invocationWrapper(code, key: key, token: token, statement: false))
            guard expressionAck.isEmpty || expressionAck == "\(token):executed" else { throw TransferFailure.malformed }
            executionConfirmed = expressionAck == "\(token):executed"
            var state = try metadata(await evaluate(metadataScript))
            if state.0 == .prepared && executionConfirmed { throw TransferFailure.malformed }
            if state.0 == .prepared && allowStatements {
                let statementAck = try await evaluate(JSWrapper.invocationWrapper(code, key: key, token: token, statement: true))
                guard statementAck.isEmpty || statementAck == "\(token):executed" else { throw TransferFailure.malformed }
                executionConfirmed = statementAck == "\(token):executed"
                state = try metadata(await evaluate(metadataScript))
            }
            if state.0 == .prepared {
                guard !executionConfirmed else { throw TransferFailure.malformed }
                throw SafariBrowserError.appleScriptFailed("JavaScript syntax error: the provided code did not parse in the supported expression or function-body form")
            }
            guard state.0 == .done || state.0 == .error else { throw TransferFailure.unavailable }
            executionConfirmed = true // Fresh completed metadata independently confirms execution.
            let value = try await readResult(length: state.1, chunked: chunked, evaluate: evaluate)
            if state.0 == .error {
                throw SafariBrowserError.appleScriptFailed("JavaScript error: \(value)\(JSWrapper.cspEvalHint(for: value) ?? "")")
            }
            _ = try? await evaluate(cleanupScript)
            return value
        } catch {
            // Cleanup is best effort when the page/transport has disappeared;
            // never erase another call or replace the original failure.
            _ = try? await evaluate(cleanupScript)
            if executionConfirmed {
                if case TransferFailure.unavailable = error { throw TransferFailure.executionResultLost }
                if let bridgeError = error as? SafariBrowserError, SafariBridge.isTargetDangleError(bridgeError) {
                    throw TransferFailure.executionResultLost
                }
            }
            throw error
        }
    }
}
