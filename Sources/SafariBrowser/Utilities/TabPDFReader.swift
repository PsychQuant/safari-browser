import Darwin
import Foundation

/// Reads the PDF a tab displays from what WebKit already holds (#338).
///
/// A response marked `no-store` never reaches the disk cache `pdf-cache` reads, but WebKit keeps the
/// displayed document in memory, and `fetch(location.href, {cache: 'only-if-cached'})` answers from there.
/// That cache mode cannot reach the network: without a held copy it rejects. This is the only fetch in the
/// script, and a rejection is a failure: there is no second attempt in any other mode.
///
/// A service worker sees every fetch of the page it controls and can answer from the network, so such a
/// page is refused rather than read.
enum TabPDFReader {
    /// Refused before encoding: base64 grows the bytes by 4/3, and each 262,144 units is one `do JavaScript`.
    static let maxBytes = 268_435_456
    /// `only-if-cached` answers from memory; this bounds a page that never settles.
    static let deadlineSeconds: Double = 60
    private static let pollNanoseconds: UInt64 = 100_000_000
    private static let detailLimit = 200

    struct Read: Equatable {
        let bytes: Data
        let url: String
    }

    enum Status: Equatable {
        case gone
        case wait
        case ok(bytes: Int, length: Int)
        case failed(SavePDFFailure)
        case damaged(String)
    }

    // MARK: - scripts

    /// Starts the read and returns at once; `statusScript` says when it is done. Nothing is declared in the
    /// page's scope. The slot exists before anything can fail, so every outcome is recorded on it.
    static func startScript(slot: ResultSlot, maxBytes: Int = TabPDFReader.maxBytes) -> String {
        let ref = "window.\(slot.key)"
        return """
            (\(ResultSlot.sweepExpression), \(ref) = { u: \(ResultSlot.stampExpression) }, (function(s){
              function fail(code, detail) { s.fail = code; s.detail = ('' + detail).slice(0, \(detailLimit)); s.done = true; }
              try {
                if (document.contentType !== 'application/pdf') { fail('not-pdf', document.contentType); return; }
                if (navigator.serviceWorker && navigator.serviceWorker.controller) { fail('service-worker', ''); return; }
                s.url = location.href;
                fetch(location.href, { cache: 'only-if-cached', mode: 'same-origin' })
                  .then(function(r){ if (!r.ok) { fail('status', r.status); return null; } return r.blob(); })
                  .then(function(b){ if (!b) { return null; } s.bytes = b.size;
                    if (b.size > \(maxBytes)) { fail('too-large', b.size); return null; }
                    return new Promise(function(res, rej){ var f = new FileReader();
                      f.onload = function(){ res(f.result); }; f.onerror = function(){ rej(f.error); }; f.readAsDataURL(b); }); })
                  .then(function(u){ if (u === null) { return; } var t = u.slice(u.indexOf(',') + 1); s.text = t; s.len = t.length; s.done = true; })
                  .catch(function(e){ fail('not-held', e && e.message !== undefined ? e.message : e); });
              } catch (e) { fail('not-held', e && e.message !== undefined ? e.message : e); }
            })(\(ref)), 1)
            """
    }

    /// One of the four closed answers `parseStatus` reads.
    static func statusScript(slot: ResultSlot) -> String {
        "(function(){ var s = window.\(slot.key); if (!s) { return 'gone'; } \(ResultSlot.touchStatement) if (!s.done) { return 'wait'; } return s.fail ? 'fail:' + s.fail + ':' + s.detail : 'ok:' + s.bytes + ':' + s.len; })()"
    }

    private static func urlScript(slot: ResultSlot) -> String {
        "(function(){ var s = window.\(slot.key); return s && s.url ? s.url : ''; })()"
    }

    /// Anything outside the closed format is damaged, never read as a result.
    static func parseStatus(_ raw: String) -> Status {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "gone" { return .gone }
        if text == "wait" { return .wait }
        func number(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            return Int(part)
        }
        if text.hasPrefix("ok:") {
            let parts = text.dropFirst(3).split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, let bytes = number(parts[0]), let length = number(parts[1]) {
                return .ok(bytes: bytes, length: length)
            }
            return .damaged("unexpected status")
        }
        if text.hasPrefix("fail:") {
            let rest = text.dropFirst(5)
            guard let colon = rest.firstIndex(of: ":") else { return .damaged("unexpected status") }
            let detail = rest[rest.index(after: colon)...]
            switch rest[..<colon] {
            case "not-pdf": return .failed(.notPDF(contentType: String(detail)))
            case "service-worker": return .failed(.serviceWorker)
            case "not-held": return .failed(.notHeld(detail: String(detail)))
            case "status":
                if let code = number(detail) { return .failed(.badStatus(code: code)) }
            case "too-large":
                if let bytes = number(detail) { return .failed(.tooLarge(bytes: bytes)) }
            default: break
            }
        }
        return .damaged("unexpected status")
    }

    // MARK: - reading

    /// `target` is expected to be already resolved once (`resolveToAnchoredTarget`), so every step addresses
    /// the same tab. The slot is removed at the end, except after a timeout: the page is busy then, and a
    /// removal would wait as long again. An abandoned slot is reclaimed later (#193).
    static func read(
        target: SafariBridge.TargetDocument, firstMatch: Bool = false,
        deadlineSeconds: Double = TabPDFReader.deadlineSeconds
    ) async throws -> Read {
        let slot = ResultSlot.make()
        func run(_ script: String) async throws -> String {
            try await SafariBridge.doJavaScript(script, target: target, firstMatch: firstMatch)
        }
        do {
            _ = try await run(startScript(slot: slot))
            let (bytes, length) = try await awaitCompletion(slot: slot, deadlineSeconds: deadlineSeconds, run: run)
            let url = try await run(urlScript(slot: slot))
            let text: String
            do {
                text = length > 0
                    ? try await SafariBridge.readResultSlot(slot, length: length, target: target, firstMatch: firstMatch) : ""
            } catch where ResultSlot.isIncompleteTransfer(error) {
                // The chunk read answers nothing when the slot is gone. Ask, because the two mean different things.
                if case .gone = parseStatus(try await run(statusScript(slot: slot))) { throw SafariBrowserError.savePDF(.pageReplaced) }
                throw SafariBrowserError.savePDF(.damagedReply(detail: "\(error.localizedDescription)"))
            }
            guard let decoded = Data(base64Encoded: text) else {
                throw SafariBrowserError.savePDF(.damagedReply(detail: "the bytes did not decode"))
            }
            guard decoded.count == bytes else {
                throw SafariBrowserError.savePDF(.damagedReply(detail: "\(decoded.count) bytes arrived where \(bytes) were announced"))
            }
            await SafariBridge.removeResultSlot(slot, target: target, firstMatch: firstMatch)
            return Read(bytes: decoded, url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if case SafariBrowserError.savePDF(.timedOut) = error { throw error }
            await SafariBridge.removeResultSlot(slot, target: target, firstMatch: firstMatch, after: error)
            throw error
        }
    }

    private static func awaitCompletion(
        slot: ResultSlot, deadlineSeconds: Double, run: (String) async throws -> String
    ) async throws -> (bytes: Int, length: Int) {
        let started = ContinuousClock.now
        while true {
            switch parseStatus(try await run(statusScript(slot: slot))) {
            case .ok(let bytes, let length): return (bytes, length)
            case .failed(let failure): throw SafariBrowserError.savePDF(failure)
            case .gone: throw SafariBrowserError.savePDF(.pageReplaced)
            case .damaged(let detail): throw SafariBrowserError.savePDF(.damagedReply(detail: detail))
            case .wait: break
            }
            if ContinuousClock.now - started >= .seconds(deadlineSeconds) {
                throw SafariBrowserError.savePDF(.timedOut(seconds: deadlineSeconds))
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    // MARK: - publishing

    /// Writes the bytes owner-only into a private folder and hands that file to `PDFCacheOutput.copyVerified`,
    /// which is the same path a cached PDF takes: `%PDF-`, readable pages, `--force`, one anchored folder.
    /// The private folder is removed whatever happens.
    static func publish(
        _ read: Read, to destination: String, force: Bool,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> PDFCacheOutput.Result {
        var template = Array(stagingRoot.appendingPathComponent("safari-browser-save-pdf-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw SafariBrowserError.savePDF(.stagingFailed(detail: String(cString: strerror(errno))))
        }
        let folder = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent("tab-document.pdf")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SafariBrowserError.savePDF(.stagingFailed(detail: String(cString: strerror(errno)))) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: read.bytes)
            try handle.close()
        } catch {
            throw SafariBrowserError.savePDF(.stagingFailed(detail: error.localizedDescription))
        }
        return try PDFCacheOutput.copyVerified(
            from: staged, to: destination, force: force, protectedFolders: [WebKitCacheReader.defaultCacheRoot],
            expectedSize: Int64(read.bytes.count))
    }
}
