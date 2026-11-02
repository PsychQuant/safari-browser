import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// `save-pdf` (#338). The page script really runs, in `FakePage`; `document`, `navigator`, `location`, `fetch`
/// and `FileReader` are shims that record what the script asked for. What these shims cannot show (that
/// `only-if-cached` stays off the network on a real Safari) is the job of `Tests/e2e-save-pdf.sh`.
enum TabPDFFixture {
    static let signedURL = "https://cdn.example.org/1-s2.0/main.pdf?X-Amz-Signature=SECRET#page=2"

    /// A real PDF CoreGraphics can read, padded with an unused stream to reach `padding` bytes.
    static func pdf(padding: Int = 0) -> Data {
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>".utf8),
            Data("<< /Length \(padding) >>\nstream\n".utf8) + Data(repeating: 0x41, count: padding) + Data("\nendstream".utf8),
        ]
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.count)
            out += Data("\(i + 1) 0 obj\n".utf8) + object + Data("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Data(table.utf8)
    }

    /// A page displaying `bytes`, with shims around what the script may touch.
    static func page(
        bytes: Data = pdf(), contentType: String = "application/pdf", status: Int = 200,
        reject: Bool = false, serviceWorker: Bool = false, reportedSize: Int? = nil, neverSettles: Bool = false,
        url: String = signedURL
    ) -> FakePage {
        let page = FakePage()
        install(on: page, bytes: bytes, contentType: contentType, status: status, reject: reject,
                serviceWorker: serviceWorker, reportedSize: reportedSize, neverSettles: neverSettles, url: url)
        return page
    }

    static func install(
        on page: FakePage, bytes: Data = pdf(), contentType: String = "application/pdf", status: Int = 200,
        reject: Bool = false, serviceWorker: Bool = false, reportedSize: Int? = nil, neverSettles: Bool = false,
        url: String = signedURL
    ) {
        let parts = URLComponents(string: url)
        _ = page.evaluate("""
            var __fetches = [], __readers = 0;
            var document = { contentType: '\(contentType)' };
            var location = { href: '\(url)', protocol: '\(parts?.scheme ?? "https"):', host: '\(parts?.host ?? "")', pathname: '\(parts?.percentEncodedPath ?? "")' };
            var navigator = { serviceWorker: { controller: \(serviceWorker ? "{}" : "null") } };
            function FileReader() { __readers++; }
            FileReader.prototype.readAsDataURL = function (b) {
                var self = this; self.result = 'data:application/pdf;base64,' + b.b64;
                Promise.resolve().then(function () { self.onload(); });
            };
            function fetch(u, o) {
                __fetches.push(JSON.stringify({ u: u, o: o }));
                \(neverSettles ? "return new Promise(function () {});" : "")
                \(reject ? "return Promise.reject(new TypeError('Load failed'));" : "")
                return Promise.resolve({ ok: \(status) >= 200 && \(status) < 300, status: \(status),
                    blob: function () { return Promise.resolve({ size: \(reportedSize ?? bytes.count), b64: '\(bytes.base64EncodedString())' }); } });
            }
            """)
    }

    static func fetches(_ page: FakePage) -> [String] {
        (page.evaluate("__fetches.join('\\n')") ?? "").split(separator: "\n").map(String.init)
    }
}

final class TabPDFReaderScriptTests: XCTestCase {
    private func run(_ page: FakePage, _ slot: ResultSlot = .make()) throws -> String {
        XCTAssertEqual(page.evaluate(TabPDFReader.startScript(slot: slot)), "started")
        return page.evaluate(TabPDFReader.statusScript(slot: slot)) ?? ""
    }

    func testThePageParksBase64InTheCallsOwnSlotAndFetchesOnceFromTheCacheOnly() throws {
        let bytes = TabPDFFixture.pdf()
        let page = TabPDFFixture.page(bytes: bytes)
        let slot = ResultSlot.make()
        let status = try run(page, slot)
        XCTAssertEqual(status, "ok:\(bytes.count):\(bytes.base64EncodedString().count)")
        XCTAssertEqual(page.evaluate("window.\(slot.key).text"), bytes.base64EncodedString())
        let fetches = TabPDFFixture.fetches(page)
        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(fetches[0].contains("\"cache\":\"only-if-cached\""), fetches[0])
        XCTAssertTrue(fetches[0].contains("\"mode\":\"same-origin\""), fetches[0])
        XCTAssertTrue(fetches[0].contains("\"u\":\"\(TabPDFFixture.signedURL)\""), fetches[0])
    }

    func testADocumentThatIsNotAPDFIsNotFetched() throws {
        let page = TabPDFFixture.page(contentType: "text/html")
        XCTAssertEqual(try run(page), "fail:not-pdf:text/html")
        XCTAssertEqual(TabPDFFixture.fetches(page), [])
    }

    func testBothPDFTypesWebKitDisplaysAreRead() throws {
        XCTAssertTrue(try run(TabPDFFixture.page(contentType: "text/pdf")).hasPrefix("ok:"))
    }

    func testAPageUnderAServiceWorkerIsNotFetched() throws {
        let page = TabPDFFixture.page(serviceWorker: true)
        XCTAssertEqual(try run(page), "fail:service-worker:")
        XCTAssertEqual(TabPDFFixture.fetches(page), [])
    }

    func testANavigatorWithoutServiceWorkerIsNotAnError() throws {
        let page = TabPDFFixture.page()
        _ = page.evaluate("navigator = {};")
        XCTAssertTrue(try run(page).hasPrefix("ok:"))
    }

    func testARejectedFetchIsReportedAsNotHeldByNameOnly() throws {
        let page = TabPDFFixture.page()
        _ = page.evaluate("fetch = function () { return Promise.reject(new TypeError('Load failed for https://x/?SECRET')); };")
        XCTAssertEqual(try run(page), "fail:not-held:TypeError")
    }

    /// The signed query never crosses into a script (an `osascript` argument, part of a timeout message) and
    /// only the protocol, host and path come back.
    func testTheAddressStaysInThePage() throws {
        let slot = ResultSlot.make()
        let page = TabPDFFixture.page()
        let script = TabPDFReader.startScript(slot: slot)
        XCTAssertFalse(script.contains("SECRET"))
        XCTAssertFalse(script.contains("cdn.example.org"))
        _ = try run(page, slot)
        XCTAssertEqual(page.evaluate("window.\(slot.key).shown"), "https://cdn.example.org/1-s2.0/main.pdf")
    }

    func testAnErrorStatusIsReported() throws {
        XCTAssertEqual(try run(TabPDFFixture.page(status: 504)), "fail:status:504")
    }

    func testAStatusOtherThan200IsNotRead() throws {
        let page = TabPDFFixture.page(status: 206)
        XCTAssertEqual(try run(page), "fail:status:206")
        XCTAssertEqual(page.evaluate("'' + __readers"), "0")
    }

    func testAFailureAfterTheFetchAnsweredIsNotCalledNotHeld() throws {
        let body = TabPDFFixture.page()
        _ = body.evaluate("fetch = function () { return Promise.resolve({ status: 200, blob: function () { return Promise.reject(new RangeError('x')); } }); };")
        XCTAssertEqual(try run(body), "fail:read-failed:RangeError")

        let reader = TabPDFFixture.page()
        _ = reader.evaluate("FileReader.prototype.readAsDataURL = function () { var self = this; self.error = new Error('x'); self.error.name = 'NotReadableError'; Promise.resolve().then(function () { self.onerror(); }); };")
        XCTAssertEqual(try run(reader), "fail:read-failed:NotReadableError")
    }

    func testAContentTypeWithACommaStillGivesTheBase64() throws {
        let bytes = TabPDFFixture.pdf()
        let page = TabPDFFixture.page(bytes: bytes)
        _ = page.evaluate("FileReader.prototype.readAsDataURL = function (b) { var self = this; self.result = 'data:application/pdf; name=\"a, b.pdf\";base64,' + b.b64; Promise.resolve().then(function () { self.onload(); }); };")
        let slot = ResultSlot.make()
        XCTAssertTrue(try run(page, slot).hasPrefix("ok:"))
        XCTAssertEqual(page.evaluate("window.\(slot.key).text"), bytes.base64EncodedString())
    }

    func testADataURLWithNoCommaIsEmptyNotItsOwnPrefix() throws {
        let page = TabPDFFixture.page(bytes: Data())
        _ = page.evaluate("FileReader.prototype.readAsDataURL = function () { var self = this; self.result = 'data:'; Promise.resolve().then(function () { self.onload(); }); };")
        XCTAssertEqual(try run(page), "ok:0:0")
    }

    func testAResultOverTheLimitIsNotEncoded() throws {
        let page = TabPDFFixture.page(reportedSize: TabPDFReader.maxBytes + 1)
        XCTAssertEqual(try run(page), "fail:too-large:\(TabPDFReader.maxBytes + 1)")
        XCTAssertEqual(page.evaluate("'' + __readers"), "0")
    }

    func testAScriptThatFailsOutrightStillFinishes() throws {
        let page = TabPDFFixture.page()
        _ = page.evaluate("fetch = function () { throw new Error('boom'); };")
        XCTAssertEqual(try run(page), "fail:read-failed:Error")
    }

    func testTheScriptNamesNoOtherWayToTheNetwork() {
        let script = TabPDFReader.startScript(slot: .make())
        XCTAssertEqual(script.components(separatedBy: "fetch(").count - 1, 1)
        XCTAssertTrue(script.contains("cache: 'only-if-cached'"))
        for token in ["XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "importScripts", "force-cache", "no-store",
                      "'reload'", "no-cache", "location.reload", "location.assign", "window.open", "createElement"] {
            XCTAssertFalse(script.contains(token), token)
        }
    }

    func testTheScriptDeclaresNoGlobal() throws {
        let page = TabPDFFixture.page()
        let before = page.windowKeys()
        let slot = ResultSlot.make()
        _ = try run(page, slot)
        XCTAssertEqual(page.windowKeys().subtracting(before), [slot.key])
    }
}

final class TabPDFReaderStatusTests: XCTestCase {
    func testTheFourAnswers() {
        XCTAssertEqual(TabPDFReader.parseStatus("gone"), .gone)
        XCTAssertEqual(TabPDFReader.parseStatus("wait"), .wait)
        XCTAssertEqual(TabPDFReader.parseStatus("ok:12:16"), .ok(bytes: 12, length: 16))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:not-held:a:b"), .failed(.notHeld(detail: "a:b")))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:not-pdf:text/html"), .failed(.notPDF(contentType: "text/html")))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:service-worker:"), .failed(.serviceWorker))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:status:504"), .failed(.badStatus(code: 504)))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:too-large:9"), .failed(.tooLarge(bytes: 9)))
        XCTAssertEqual(TabPDFReader.parseStatus("fail:read-failed:Error"), .failed(.readFailed(detail: "Error")))
    }

    func testADetailStartingWithACombiningMarkKeepsItsCode() {
        XCTAssertEqual(TabPDFReader.parseStatus("fail:not-held:\u{0301}Load failed"), .failed(.notHeld(detail: "\u{0301}Load failed")))
    }

    func testAnythingElseIsADamagedReply() {
        for raw in ["", "missing value", "ok", "ok:1", "ok:a:b", "ok:1:2:3", "ok:-1:2", "fail", "fail:", "fail:unknown:x",
                    "fail:status:abc", "fail:too-large:x", "waiting"] {
            guard case .damaged = TabPDFReader.parseStatus(raw) else { return XCTFail("'\(raw)' was accepted") }
        }
    }
}

final class TabPDFReaderFlowTests: XCTestCase, @unchecked Sendable {
    private let target = SafariBridge.TargetDocument.resolvedTab(windowID: 7, tabInWindow: 1, rematch: nil, profile: nil)

    private func read(_ page: FakePage, deadline: Double = 5) async throws -> TabPDFReader.Read {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try page.respond($0) }) {
                    try await TabPDFReader.read(target: self.target, deadlineSeconds: deadline)
                }
            }
        }
    }

    private func failure(_ page: FakePage, deadline: Double = 5) async -> SavePDFFailure? {
        do { _ = try await read(page, deadline: deadline); return nil }
        catch SafariBrowserError.savePDF(let failure) { return failure }
        catch { XCTFail("\(error)"); return nil }
    }

    func testBytesAcrossSeveralChunksComeBackExactlyAndTheSlotIsRemoved() async throws {
        let bytes = TabPDFFixture.pdf(padding: 800_000)
        let page = TabPDFFixture.page(bytes: bytes)
        let result = try await read(page)
        XCTAssertEqual(result.bytes, bytes)
        XCTAssertEqual(result.url, "https://cdn.example.org/1-s2.0/main.pdf")
        XCTAssertFalse(page.sent.contains { $0.contains("SECRET") }, "the signed query must not be in any script")
        XCTAssertEqual(page.keys(withPrefix: ResultSlot.keyPrefix), [])
        XCTAssertGreaterThan(page.javaScripts.filter { $0.contains("substring(") }.count, 1)
    }

    func testThePageBeingReplacedBeforeAChunkIsAFailure() async {
        let page = TabPDFFixture.page(bytes: TabPDFFixture.pdf(padding: 800_000))
        var chunks = 0
        page.beforeRun = { script in
            guard script.contains("substring(") else { return }
            chunks += 1
            if chunks == 2 { page.replaceDocument() }
        }
        let got = await failure(page)
        XCTAssertEqual(got, .pageReplaced)
    }

    func testThePageBeingReplacedBeforeTheStatusIsAFailure() async {
        let page = TabPDFFixture.page()
        page.beforeRun = { script in if script.contains("'wait'") { page.replaceDocument() } }
        let got = await failure(page)
        XCTAssertEqual(got, .pageReplaced)
    }

    func testAPageThatNeverFinishesTimesOutAndTheSlotIsRemoved() async {
        let page = TabPDFFixture.page(neverSettles: true)
        let got = await failure(page, deadline: 0.2)
        XCTAssertEqual(got, .timedOut(seconds: 0.2))
        XCTAssertEqual(page.keys(withPrefix: ResultSlot.keyPrefix), [])
    }

    /// WebKit refuses to run anything in a PDF that is still loading, and `do JavaScript` then answers nothing.
    func testATabThatRunsNoScriptsIsSaidToBeThatNotDamaged() async {
        let page = TabPDFFixture.page()
        page.forced = { $0.contains("only-if-cached") ? "" : nil }
        let got = await failure(page)
        XCTAssertEqual(got, .notScriptable)
    }

    func testTheDeadlineCountsFromTheStartAndALateAnswerIsNotTaken() async {
        let page = TabPDFFixture.page()
        let got = await failure(page, deadline: 0)
        XCTAssertEqual(got, .timedOut(seconds: 0))
    }

    func testNumbersThePageCouldNotHaveAreADamagedReplyAndNothingIsRead() async {
        let tooMany = "ok:\(TabPDFReader.maxBytes + 1):\((TabPDFReader.maxBytes + 3) / 3 * 4)"
        for reply in [tooMany, "ok:3:400000000"] {
            let page = TabPDFFixture.page()
            page.forced = { $0.contains("'wait'") ? reply : nil }
            guard case .damagedReply? = await failure(page) else { return XCTFail("accepted \(reply)") }
            XCTAssertFalse(page.javaScripts.contains { $0.contains("substring(") }, reply)
        }
    }

    func testAByteCountThatDoesNotMatchIsADamagedReply() async {
        let page = TabPDFFixture.page(reportedSize: 1)
        guard case .damagedReply? = await failure(page) else { return XCTFail("accepted") }
    }

    func testBase64ThatDoesNotDecodeIsADamagedReply() async {
        let page = TabPDFFixture.page()
        _ = page.evaluate("FileReader.prototype.readAsDataURL = function (b) { var self = this; self.result = 'data:x;base64,' + new Array(Math.ceil(b.size / 3) * 4 + 1).join('!'); Promise.resolve().then(function () { self.onload(); }); };")
        guard case .damagedReply? = await failure(page) else { return XCTFail("accepted") }
    }

    func testAReplyOutsideTheFormatIsADamagedReply() async {
        let page = TabPDFFixture.page()
        page.forced = { $0.contains("'wait'") ? "surprise" : nil }
        guard case .damagedReply? = await failure(page) else { return XCTFail("accepted") }
    }

    func testAFailureRemovesTheSlot() async {
        let page = TabPDFFixture.page(reject: true)
        let got = await failure(page)
        XCTAssertEqual(got, .notHeld(detail: "TypeError"))
        XCTAssertEqual(page.keys(withPrefix: ResultSlot.keyPrefix), [])
    }

    func testTwoCallsOnOnePageEachGetTheWholeDocument() async throws {
        let bytes = TabPDFFixture.pdf(padding: 600_000)
        let page = TabPDFFixture.page(bytes: bytes)
        async let first = read(page)
        async let second = read(page)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.bytes, bytes)
        XCTAssertEqual(b.bytes, bytes)
    }
}

final class SavePDFFailureTests: XCTestCase {
    func testEveryMessageSaysNothingWasRequestedWhereItMatters() {
        XCTAssertTrue(SavePDFFailure.notHeld(detail: "Load failed").message.contains("No request for the document was sent"))
        XCTAssertTrue(SavePDFFailure.serviceWorker.message.contains("service worker"))
        XCTAssertTrue(SavePDFFailure.notPDF(contentType: "text/html").message.contains("text/html"))
        XCTAssertTrue(SavePDFFailure.tooLarge(bytes: 9).message.contains("\(TabPDFReader.maxBytes)"))
        for failure: SavePDFFailure in [.readFailed(detail: "Error"), .bytesNotPDF, .badStatus(code: 206)] {
            XCTAssertTrue(failure.message.contains("No request was sent"), failure.message)
        }
        XCTAssertTrue(SavePDFFailure.notScriptable.message.contains("no request was sent"))
    }

    func testAHostileDetailStaysOnOneLine() {
        let message = SavePDFFailure.notHeld(detail: "a\u{1B}[31m\nb").message
        XCTAssertFalse(message.contains("\u{1B}"))
    }
}

final class SavePDFPublishTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var staging: URL { folder.appendingPathComponent("staging") }

    private func publish(
        _ bytes: Data, to name: String = "out.pdf", force: Bool = false, protectedFolder: URL? = nil
    ) throws -> PDFCacheOutput.Result {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try TabPDFReader.publish(.init(bytes: bytes, url: TabPDFFixture.signedURL),
                                        to: folder.appendingPathComponent(name).path, force: force, stagingRoot: staging,
                                        protectedFolder: protectedFolder ?? folder.appendingPathComponent("no-such-folder"))
    }

    private func makeFolder(_ name: String, mode: Int16) throws -> URL {
        let made = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: made.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: Int16(0o700)], ofItemAtPath: made.path) }
        return made
    }

    private func canonical(_ url: URL) -> URL {
        let resolved = realpath(url.path, nil)
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved!))
    }

    /// A process without Full Disk Access must not touch Safari's container, not even to be refused: the first
    /// version failed there after the whole transfer, and opening it can raise a dialog. A symlink to the
    /// destination's own folder shows the path is compared as given: opening or resolving it would refuse this.
    func testTheCacheFolderIsComparedByItsPathAndNeverFollowed() throws {
        let link = folder.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertEqual(try publish(TabPDFFixture.pdf(), protectedFolder: link).pages, 1)
    }

    func testADestinationInsideTheCacheFolderIsRefused() throws {
        let sub = try makeFolder("cache/sub", mode: 0o700)
        let cache = canonical(folder.appendingPathComponent("cache"))
        XCTAssertThrowsError(try publish(TabPDFFixture.pdf(), to: "cache/sub/out.pdf", protectedFolder: cache)) { error in
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed(_, let detail)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "it is inside Safari's own cache folder")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.appendingPathComponent("out.pdf").path))
    }

    func testAFolderWhoseNameStartsWithACombiningMarkIsStillInside() throws {
        _ = try makeFolder("cache/\u{0301}x", mode: 0o700)
        let cache = canonical(folder.appendingPathComponent("cache"))
        XCTAssertThrowsError(try publish(TabPDFFixture.pdf(), to: "cache/\u{0301}x/out.pdf", protectedFolder: cache)) { error in
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed) = error else { return XCTFail("\(error)") }
        }
    }

    func testTheDefaultCacheFolderIsSafarisWithOnlyTheHomeResolved() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(TabPDFReader.cacheFolderPath.path,
                       canonical(home).path + "/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/WebKitCache")
    }

    /// A temporary folder can hand down an inheritable ACL; the mode bits alone would not keep other users out.
    func testTheStagedFileDropsAnInheritedACL() throws {
        func lines(_ path: String) throws -> String {
            let ls = Process()
            ls.executableURL = URL(fileURLWithPath: "/bin/ls")
            ls.arguments = ["-le", path]
            let out = Pipe()
            ls.standardOutput = out
            try ls.run()
            ls.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let inheriting = try makeFolder("inheriting", mode: 0o700)
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow read,file_inherit,directory_inherit", inheriting.path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertEqual(acl.terminationStatus, 0)
        let control = inheriting.appendingPathComponent("control")
        try Data("x".utf8).write(to: control)
        XCTAssertTrue(try lines(control.path).contains("group:everyone"), "the fixture hands down no ACL")
        let staged = try TabPDFReader.stage(TabPDFFixture.pdf(), in: inheriting)
        XCTAssertFalse(try lines(staged.path).contains("group:everyone"))
    }

    func testPDFCacheStillDoesNotPassAFolderItCannotOpen() throws {
        let closed = try makeFolder("closed", mode: 0o000)
        let source = folder.appendingPathComponent("source.pdf")
        try TabPDFFixture.pdf().write(to: source)
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(
            from: source, to: folder.appendingPathComponent("out.pdf").path, force: false, protectedFolders: [closed])) { error in
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed(_, let detail)) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("could not be checked"), detail)
        }
    }

    func testAReadablePDFIsPublishedOwnerOnlyAndTheStagingFolderIsGone() throws {
        let bytes = TabPDFFixture.pdf()
        let result = try publish(bytes)
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("out.pdf")), bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("out.pdf").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testBytesThatAreNotAPDFLeaveNothing() throws {
        XCTAssertThrowsError(try publish(Data("<html>".utf8))) { error in
            guard case SafariBrowserError.savePDF(.bytesNotPDF) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.contains("tab-document"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.pdf").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testAnExistingDestinationIsRefusedUnlessForced() throws {
        let existing = folder.appendingPathComponent("out.pdf")
        try Data("old".utf8).write(to: existing)
        XCTAssertThrowsError(try PDFCacheOutput.refuseExistingDestination(existing.path, force: false)) { error in
            guard case SafariBrowserError.pdfCache(.destinationExists) = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try PDFCacheOutput.refuseExistingDestination(existing.path, force: true))
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        _ = try publish(TabPDFFixture.pdf(), force: true)
        XCTAssertEqual(try Data(contentsOf: existing), TabPDFFixture.pdf())
    }

    func testAMissingFolderAndAFolderDestinationAreRefusedEarly() throws {
        XCTAssertThrowsError(try PDFCacheOutput.refuseExistingDestination(folder.appendingPathComponent("no/out.pdf").path, force: false)) { error in
            guard case SafariBrowserError.pdfCache(.destinationDirectoryMissing) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try PDFCacheOutput.refuseExistingDestination(folder.path, force: true)) { error in
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed) = error else { return XCTFail("\(error)") }
        }
    }

    func testAFileWhereTheFolderShouldBeIsRefusedEarly() throws {
        let file = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try PDFCacheOutput.refuseExistingDestination(file.appendingPathComponent("out.pdf").path, force: false)) { error in
            guard case SafariBrowserError.pdfCache(.destinationDirectoryMissing) = error else { return XCTFail("\(error)") }
        }
    }
}

final class SavePDFCommandTests: XCTestCase, @unchecked Sendable {
    private let target = ["--window", "1", "--tab-in-window", "53"]
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-pdf-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func run(
        _ args: [String], page: FakePage, fake: JSCommandRoundTripTests.FakeSafari = .init(), vanishOn: String? = nil
    ) async throws -> String {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try SavePDFCommand.parse(args)
        let out = JSCommandRoundTripTests.FDCapture(STDOUT_FILENO)
        out.start()
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                        if let vanishOn, script.contains(vanishOn) { return try fake.respond(script) }
                        return script.contains("do JavaScript") ? try page.respond(script) : try fake.respond(script)
                    }) { try await command.run() }
                }
            }
        } catch { _ = out.stop(); throw error }
        return out.stop()
    }

    func testNoTargetIsAUsageErrorBeforeAnythingRuns() {
        for args in [["out.pdf"], ["out.pdf", "--first-match"], ["out.pdf", "--force", "--json"]] {
            XCTAssertThrowsError(try SavePDFCommand.parse(args), "\(args)") { error in
                XCTAssertEqual(SafariBrowser.exitCode(for: error).rawValue, 64)
                XCTAssertTrue(SafariBrowser.message(for: error).contains("--url"), SafariBrowser.message(for: error))
            }
        }
    }

    /// Were `profile:` dropped from the resolution, the read would go to another profile's tab.
    func testAProfileWithNoSuchTabStopsTheCommand() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        let page = TabPDFFixture.page()
        do {
            _ = try await run([path, "--url", "w1.example/1", "--profile", "其他"], page: page)
            XCTFail("accepted")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertEqual(page.sent, [])
    }

    func testProfileIsAccepted() throws {
        XCTAssertNoThrow(try SavePDFCommand.parse(["out.pdf", "--url", "x", "--profile", "個人"]))
        XCTAssertTrue(TargetOptions.honoredProfileCommandsHelp.contains("save-pdf"))
    }

    func testTheOutputLineHasNoQuery() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        let page = TabPDFFixture.page()
        let line = try await run([path] + target, page: page)
        XCTAssertFalse(line.contains("SECRET"), line)
        XCTAssertTrue(line.contains("from tab https://cdn.example.org/1-s2.0/main.pdf"), line)
        XCTAssertTrue(line.contains("1 page(s)"), line)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), TabPDFFixture.pdf())
    }

    func testThePathParametersAndCredentialsAreNotPrinted() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        let page = TabPDFFixture.page(url: "https://cdn.example.org/x;jsessionid=SECRET/main.pdf")
        let line = try await run([path, "--json"] + target, page: page)
        XCTAssertFalse(line.contains("SECRET"), line)
    }

    /// A tab that vanishes names the target. The untranslated error lists every profile's tabs, and this
    /// Mac has other people's profiles in Safari.
    func testAVanishedTabDoesNotListOtherTabs() async throws {
        for args in [target, ["--window", "1"]] {
            let path = folder.appendingPathComponent("gone-\(args.count).pdf").path
            let fake = JSCommandRoundTripTests.FakeSafari(failJSContaining: "only-if-cached")
            do {
                _ = try await run([path] + args, page: TabPDFFixture.page(), fake: fake, vanishOn: "only-if-cached")
                XCTFail("accepted")
            } catch let error as SafariBrowserError {
                guard case .anchoredTargetChanged = error else { return XCTFail("\(args): \(error)") }
                XCTAssertFalse(error.localizedDescription.contains("w2.example"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testJSONHasTheFiveFieldsAndNoQuery() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        let output = try await run([path, "--json"] + target, page: TabPDFFixture.page())
        XCTAssertFalse(output.contains("SECRET"), output)
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys ?? [:].keys), ["path", "size", "pages", "source", "url"])
        XCTAssertEqual(object?["source"] as? String, "tab")
        XCTAssertEqual(object?["pages"] as? Int, 1)
        XCTAssertEqual(object?["size"] as? Int, TabPDFFixture.pdf().count)
    }

    func testAnExistingDestinationStopsBeforeAnyScriptRuns() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        let page = TabPDFFixture.page()
        let fake = JSCommandRoundTripTests.FakeSafari()
        do { _ = try await run([path] + target, page: page, fake: fake); XCTFail("accepted") }
        catch SafariBrowserError.pdfCache(.destinationExists) {}
        XCTAssertEqual(page.sent, [])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("old".utf8))
    }

    func testAFailureLeavesNoFileAndNoSecretInTheMessage() async throws {
        let path = folder.appendingPathComponent("out.pdf").path
        do { _ = try await run([path] + target, page: TabPDFFixture.page(reject: true)); XCTFail("accepted") }
        catch { XCTAssertFalse("\(error)".contains("SECRET")); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

final class PDFCacheNamesSavePDFTests: XCTestCase {
    func testATabMissNamesSavePDFAndAKeyMissDoesNot() {
        XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: "https://e.org/a.pdf?SECRET", from: [])) { error in
            let text = (error as? SafariBrowserError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("safari-browser save-pdf"), text)
            XCTAssertFalse(text.contains("SECRET"), text)
        }
        XCTAssertFalse(PDFCacheFailure.noMatch(subject: "key x").message.contains("save-pdf"))
    }
}
