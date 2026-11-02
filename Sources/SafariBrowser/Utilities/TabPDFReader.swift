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
///
/// The scripts written here contain no address, because a script is an `osascript` argument, part of a timeout
/// message and a daemon log entry; the page reports back only the protocol, host and path. Finding the tab is
/// separate: `--url` reads the tabs' URLs as every command does.
///
/// What it saves is what the tab holds. A server that sent part of a document gives that part: most such files
/// fail the page check, and a PDF with incremental updates cut at an earlier revision does not.
enum TabPDFReader {
    /// Refused before encoding: base64 grows the bytes by 4/3, and each 262,144 units is one `do JavaScript`.
    static let maxBytes = 268_435_456
    /// `only-if-cached` answers from memory; this bounds a page that never settles. It runs from before the
    /// read is started until the page reports a result. The transfer back is not under it: each chunk is one
    /// `do JavaScript` with its own process timeout.
    static let deadlineSeconds: Double = 60
    private static let pollNanoseconds: UInt64 = 100_000_000
    private static let detailLimit = 200
    /// What the start script answers. A tab that runs no scripts answers nothing.
    private static let startedReply = "started"

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
    /// page's scope. The slot exists before anything can fail, so every outcome is recorded on it, and it exists
    /// only in this document: every later step fails if the tab shows another one by then. Only the error's name
    /// is reported, because WebKit's message text is not ours and can carry the signed URL.
    static func startScript(slot: ResultSlot, maxBytes: Int = TabPDFReader.maxBytes) -> String {
        let ref = "window.\(slot.key)"
        return """
            (\(ResultSlot.sweepExpression), \(ref) = { u: \(ResultSlot.stampExpression) }, (function(s){
              function fail(code, detail) { s.fail = code; s.detail = ('' + detail).slice(0, \(detailLimit)); s.done = true; }
              function named(e) { return e && e.name ? e.name : 'Error'; }
              try {
                var type = document.contentType;
                if (type !== 'application/pdf' && type !== 'text/pdf') { fail('not-pdf', type); return; }
                if (navigator.serviceWorker && navigator.serviceWorker.controller) { fail('service-worker', ''); return; }
                s.shown = location.protocol + '//' + location.host + location.pathname;
                fetch(location.href, { cache: 'only-if-cached', mode: 'same-origin' })
                  .then(function(r){
                    if (r.status !== 200) { fail('status', r.status); return null; }
                    return r.blob();
                  }, function(e){ fail('not-held', named(e)); return null; })
                  .then(function(b){ if (!b) { return null; } s.bytes = b.size;
                    if (b.size > \(maxBytes)) { fail('too-large', b.size); return null; }
                    return new Promise(function(res, rej){ var f = new FileReader();
                      f.onload = function(){ res(f.result); }; f.onerror = function(){ rej(f.error); }; f.readAsDataURL(b); }); })
                  .then(function(u){ if (u === null) { return; } var i = u.lastIndexOf(','); var t = i < 0 ? '' : u.slice(i + 1); s.text = t; s.len = t.length; s.done = true; })
                  .catch(function(e){ fail('read-failed', named(e)); });
              } catch (e) { fail('read-failed', named(e)); }
            })(\(ref)), '\(startedReply)')
            """
    }

    /// One of the four closed answers `parseStatus` reads.
    static func statusScript(slot: ResultSlot) -> String {
        "(function(){ var s = window.\(slot.key); if (!s) { return 'gone'; } \(ResultSlot.touchStatement) if (!s.done) { return 'wait'; } return s.fail ? 'fail:' + s.fail + ':' + s.detail : 'ok:' + s.bytes + ':' + s.len; })()"
    }

    private static func shownScript(slot: ResultSlot) -> String {
        "(function(){ var s = window.\(slot.key); return s && s.shown ? s.shown : ''; })()"
    }

    /// Anything outside the closed format is damaged, never read as a result.
    static func parseStatus(_ raw: String) -> Status {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "gone" { return .gone }
        if text == "wait" { return .wait }
        func number(_ part: some StringProtocol) -> Int? {
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
            // By Unicode scalar: a detail starting with a combining mark fuses with the colon into one
            // Character, and a Character search would not find that colon (#255).
            let rest = text.dropFirst(5).unicodeScalars
            guard let colon = rest.firstIndex(of: ":") else { return .damaged("unexpected status") }
            let detail = String(rest[rest.index(after: colon)...])
            switch String(rest[..<colon]) {
            case "not-pdf": return .failed(.notPDF(contentType: detail))
            case "service-worker": return .failed(.serviceWorker)
            case "not-held": return .failed(.notHeld(detail: detail))
            case "read-failed": return .failed(.readFailed(detail: detail))
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

    /// `target` is expected to be already resolved once (`resolveToAnchoredTarget`). Until the start script
    /// runs, a position names whatever is there and a pattern whatever matches, as for every command; from
    /// then on the slot ties the steps to that document. The slot is removed at the end, unless the tab has
    /// stopped answering (`ResultSlot.removalIsWorthTrying`). An abandoned slot is reclaimed later (#193).
    static func read(
        target: SafariBridge.TargetDocument, firstMatch: Bool = false,
        deadlineSeconds: Double = TabPDFReader.deadlineSeconds
    ) async throws -> Read {
        func run(_ script: String) async throws -> String {
            try await SafariBridge.doJavaScript(script, target: target, firstMatch: firstMatch)
        }
        let slot = ResultSlot.make()
        let deadline = ContinuousClock.now + .seconds(deadlineSeconds)
        do {
            guard try await run(startScript(slot: slot)).trimmingCharacters(in: .whitespacesAndNewlines) == startedReply else {
                throw SafariBrowserError.savePDF(.notScriptable)
            }
            let (bytes, length) = try await awaitCompletion(
                slot: slot, deadline: deadline, deadlineSeconds: deadlineSeconds, run: run)
            let shown = try await run(shownScript(slot: slot)).trimmingCharacters(in: .whitespacesAndNewlines)
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
            return Read(bytes: decoded, url: shown)
        } catch {
            await SafariBridge.removeResultSlot(slot, target: target, firstMatch: firstMatch, after: error)
            throw error
        }
    }

    /// The numbers are the page's word, so they are checked before they size anything on this side: the page
    /// script enforces the limit only for a page that did not replace it.
    private static func awaitCompletion(
        slot: ResultSlot, deadline: ContinuousClock.Instant, deadlineSeconds: Double,
        run: (String) async throws -> String
    ) async throws -> (bytes: Int, length: Int) {
        while true {
            let status = parseStatus(try await run(statusScript(slot: slot)))
            switch status {
            case .ok, .wait: break
            case .failed(let failure): throw SafariBrowserError.savePDF(failure)
            case .gone: throw SafariBrowserError.savePDF(.pageReplaced)
            case .damaged(let detail): throw SafariBrowserError.savePDF(.damagedReply(detail: detail))
            }
            if ContinuousClock.now >= deadline {
                throw SafariBrowserError.savePDF(.timedOut(seconds: deadlineSeconds))
            }
            if case .ok(let bytes, let length) = status {
                guard bytes <= maxBytes, length == (bytes + 2) / 3 * 4 else {
                    throw SafariBrowserError.savePDF(.damagedReply(detail: "the page announced \(bytes) bytes in \(length) characters"))
                }
                return (bytes, length)
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    // MARK: - publishing

    /// Writes the bytes owner-only into a private folder and hands that file to `PDFCacheOutput.copyVerified`,
    /// which is the same path a cached PDF takes: `%PDF-`, readable pages, `--force`, one anchored folder.
    /// The private folder is removed whatever happens. This command needs no Full Disk Access, so Safari's
    /// cache folder is compared by its path and never opened: without the permission that is another app's
    /// data, and touching it can raise a dialog.
    static func publish(
        _ read: Read, to destination: String, force: Bool,
        stagingRoot: URL = FileManager.default.temporaryDirectory,
        protectedFolder: URL = TabPDFReader.cacheFolderPath
    ) throws -> PDFCacheOutput.Result {
        var template = Array(stagingRoot.appendingPathComponent("safari-browser-save-pdf-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw SafariBrowserError.savePDF(.stagingFailed(detail: String(cString: strerror(errno))))
        }
        let folder = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = try stage(read.bytes, in: folder)
        do {
            return try PDFCacheOutput.copyVerified(
                from: staged, to: destination, force: force, protectedFolders: [protectedFolder],
                protectedFoldersByPathOnly: true, expectedSize: Int64(read.bytes.count))
        } catch SafariBrowserError.pdfCache(.notAPDF) {
            // Its message names the staged file, which the caller never heard of.
            throw SafariBrowserError.savePDF(.bytesNotPDF)
        }
    }

    /// Owner-only before a byte is written: a temporary folder can hand down an inheritable ACL.
    static func stage(_ bytes: Data, in folder: URL) throws -> URL {
        let staged = folder.appendingPathComponent("tab-document.pdf")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SafariBrowserError.savePDF(.stagingFailed(detail: String(cString: strerror(errno)))) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try PDFCacheOutput.restrictToOwner(fd, destination: staged.path)
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            throw SafariBrowserError.savePDF(.stagingFailed(detail: error.localizedDescription))
        }
        return staged
    }

    /// Safari's cache folder spelled as `F_GETPATH` reports a folder under it. Only the folders above the app
    /// containers are resolved, so a relocated `~/Library/Containers` is seen and nothing inside another app's
    /// container is touched to find this out.
    static var cacheFolderPath: URL {
        let containers = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Containers"
        let resolved = realpath(containers, nil)
        defer { free(resolved) }
        let base = resolved.map { String(cString: $0) } ?? containers
        return URL(fileURLWithPath: base + WebKitCacheReader.defaultCacheRoot.path.dropFirst(containers.count))
    }
}
