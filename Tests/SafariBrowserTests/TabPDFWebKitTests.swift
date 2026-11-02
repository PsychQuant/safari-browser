import WebKit
import XCTest
@testable import SafariBrowser

/// `save-pdf` on a real WebKit, with no Safari: `TabPDFReader.read` runs as it does in the command, and each
/// `do JavaScript` is evaluated in an off-screen `WKWebView` loading from a local server that logs requests.
///
/// The shims in `TabPDFReaderTests` answer what the test wrote, so they can only show the script follows its
/// assumptions. These show the assumptions: round 1 of the #338 verify added `redirected` and response-URL
/// checks that passed every shim test and could never fire on WebKit.
///
/// Off by default, because it starts WebKit processes: `make test-save-pdf-webkit`. It does not replace
/// `make test-save-pdf`: `do JavaScript` is modelled (an error answers nothing), and this is not Safari's process
/// layout, its caches or its PDF viewer settings.
final class TabPDFWebKitTests: XCTestCase, @unchecked Sendable {
    private static let serverSource = #"""
    import http.server, os, re, sys, time
    root, log = sys.argv[1], os.path.join(sys.argv[1], "requests.log")
    changing = [0]
    def note(line):
        with open(log, "a") as f: f.write(line + " t=%.2f\n" % time.time())
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass
        def send(self, name, status=200, ctype="application/pdf", extra=(), upto=None):
            data = open(os.path.join(root, name), "rb").read()
            if upto is not None: data = data[:upto]
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            for k, v in extra: self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            note("POST " + self.path + " " + body.decode("utf-8", "replace")[:600].replace("\n", " "))
            self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()
        def do_GET(self):
            path = self.path.split("?")[0]
            note("GET " + self.path + " " + self.headers.get("Range", ""))
            if path.endswith("favicon.ico"):
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
            if path == "/error.pdf": return self.send("plain.pdf", 404)
            if path == "/redirect.pdf":
                self.send_response(302); self.send_header("Location", "/landed.pdf"); self.send_header("Content-Length", "0"); self.end_headers(); return
            if path == "/landed.pdf": return self.send("plain.pdf")
            if path == "/changing.pdf":
                changing[0] += 1
                return self.send("a.pdf" if changing[0] == 1 else "b.pdf")
            if path == "/plain.html": return self.send("plain.html", ctype="text/html")
            if path == "/text.pdf": return self.send("plain.pdf", ctype="text/pdf")
            if path == "/csp.pdf": return self.send("plain.pdf", extra=[("Content-Security-Policy", "connect-src 'none'; report-uri /report")])
            if path == "/short.pdf":
                size = os.path.getsize(os.path.join(root, "plain.pdf"))
                part = size * 2 // 5
                return self.send("plain.pdf", 206, extra=[("Content-Range", "bytes 0-%d/%d" % (part - 1, size))], upto=part)
            if path == "/revision.pdf":
                upto = int(open(os.path.join(root, "revision-cut"), "r").read())
                return self.send("revision.pdf", 206, extra=[("Content-Range", "bytes 0-%d/%d" % (upto - 1, os.path.getsize(os.path.join(root, "revision.pdf"))))], upto=upto)
            if path == "/drip.pdf":
                data = open(os.path.join(root, "drip.pdf"), "rb").read()
                self.send_response(200); self.send_header("Content-Type", "application/pdf")
                self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store"); self.end_headers()
                step = len(data) // 6 + 1
                for i in range(0, len(data), step):
                    self.wfile.write(data[i:i + step]); self.wfile.flush(); time.sleep(1)
                return
            if path == "/ranged.pdf":
                data = open(os.path.join(root, "ranged.pdf"), "rb").read()
                m = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
                if m:
                    start, end = int(m[1]), min(int(m[2]) if m[2] else len(data) - 1, len(data) - 1)
                    self.send_response(206); self.send_header("Content-Type", "application/pdf")
                    self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
                    self.send_header("Content-Length", str(end - start + 1)); self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Cache-Control", "no-store"); self.end_headers()
                    self.wfile.write(data[start:end + 1]); return
                # Slowly, as over a real network: that is when the viewer asks for ranges of its own.
                self.send_response(200); self.send_header("Content-Type", "application/pdf")
                self.send_header("Content-Length", str(len(data))); self.send_header("Accept-Ranges", "bytes")
                self.send_header("Cache-Control", "no-store"); self.end_headers()
                step = len(data) // 20 + 1
                try:
                    for i in range(0, len(data), step):
                        self.wfile.write(data[i:i + step]); self.wfile.flush(); time.sleep(0.25)
                except OSError: pass
                return
            name = path.lstrip("/")
            if os.path.exists(os.path.join(root, name)): return self.send(name)
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    print(s.server_address[1], flush=True)
    s.serve_forever()
    """#

    /// One off-screen view. `evaluate` is called from a worker thread and blocks it; the view lives on the main thread.
    final class Tab: @unchecked Sendable {
        let page = FakePage()
        private var view: WKWebView?

        @MainActor func load(_ url: String) {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view = webView
            webView.load(URLRequest(url: URL(string: url)!))
        }

        @MainActor func close() {
            view?.stopLoading()
            view = nil
        }

        /// As `do JavaScript`: an error answers nothing, a value answers as AppleScript prints it.
        func evaluate(_ source: String) -> String {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var answer = ""
            DispatchQueue.main.async {
                guard let view = self.view else { done.signal(); return }
                view.evaluateJavaScript(source) { value, error in
                    if error == nil {
                        switch value {
                        case let text as String: answer = text
                        case let number as NSNumber: answer = number.stringValue
                        case nil: answer = "missing value"
                        default: answer = "\(value!)"
                        }
                    }
                    done.signal()
                }
            }
            if done.wait(timeout: .now() + 40) == .timedOut { return "" }
            return answer
        }
    }

    private var root: URL!
    private var server: Process!
    private var base = ""
    private var tabs: [Tab] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAVE_PDF_WEBKIT"] == "1",
                          "starts WebKit processes; run with `make test-save-pdf-webkit`")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("save-pdf-webkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TabPDFFixture.pdf(padding: 250_000).write(to: root.appendingPathComponent("plain.pdf"))
        try TabPDFFixture.pdf(padding: 250_001).write(to: root.appendingPathComponent("a.pdf"))
        try TabPDFFixture.pdf(padding: 300_002).write(to: root.appendingPathComponent("b.pdf"))
        try TabPDFFixture.pdf(padding: 2_000_000).write(to: root.appendingPathComponent("drip.pdf"))
        try Data("<!doctype html><title>plain</title><p>not a pdf".utf8).write(to: root.appendingPathComponent("plain.html"))
        let source = root.appendingPathComponent("server.py")
        try Data(Self.serverSource.utf8).write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", source.path, root.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        server = process
        let port = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty, "the server did not start")
        base = "http://127.0.0.1:\(port)"
    }

    override func tearDown() async throws {
        let open = tabs
        await MainActor.run { open.forEach { $0.close() } }
        tabs = []
        server?.terminate()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var log: [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// What the document's own loading asked for, without the icon WebKit fetches on its own.
    private var documentRequests: Int { log.filter { !$0.contains("favicon") && !$0.hasPrefix("POST ") }.count }

    private func open(_ path: String, type: String = "application/pdf") async throws -> Tab {
        let tab = Tab()
        tab.page.forced = { [tab] js in tab.evaluate(js) }
        tabs.append(tab)
        let url = base + path
        await MainActor.run { tab.load(url) }
        for _ in 0..<120 {
            // An empty view is `about:blank`, whose content type is text/html too.
            if tab.evaluate("document.contentType") == type, tab.evaluate("location.href") != "about:blank" { return tab }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("\(path) never showed as \(type): \(tab.evaluate("document.contentType"))")
        return tab
    }

    private func read(_ tab: Tab) async throws -> TabPDFReader.Read {
        let target = SafariBridge.TargetDocument.resolvedTab(windowID: 7, tabInWindow: 1, rematch: nil, profile: nil)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try tab.page.respond($0) }) {
                    try await TabPDFReader.read(target: target)
                }
            }
        }
    }

    private func failure(_ tab: Tab) async -> SavePDFFailure? {
        do { _ = try await read(tab); return nil }
        catch SafariBrowserError.savePDF(let failure) { return failure }
        catch { XCTFail("\(error)"); return nil }
    }

    private func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }

    func testANoStorePDFComesBackExactlyWithNoRequestAndTheQueryStaysInThePage() async throws {
        let tab = try await open("/plain.pdf?X-Amz-Signature=SECRET#page=2")
        let before = documentRequests
        XCTAssertGreaterThanOrEqual(before, 1, "the log recorded nothing, so nothing below means anything")
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, try data("plain.pdf"))
        XCTAssertEqual(result.url, base + "/plain.pdf")
        XCTAssertEqual(documentRequests, before)
        XCTAssertFalse(tab.page.sent.contains { $0.contains("SECRET") })
    }

    func testAPDFSentWith404IsSavedLikeAnyOther() async throws {
        let tab = try await open("/error.pdf")
        let before = documentRequests
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, try data("plain.pdf"))
        XCTAssertEqual(documentRequests, before)
    }

    func testATabThatArrivedThroughARedirectIsSaved() async throws {
        let tab = try await open("/redirect.pdf")
        let before = documentRequests
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, try data("plain.pdf"))
        XCTAssertEqual(result.url, base + "/landed.pdf")
        XCTAssertEqual(documentRequests, before)
    }

    func testTwoViewsOnOneURLEachGiveTheirOwnDocument() async throws {
        let first = try await open("/changing.pdf")
        let second = try await open("/changing.pdf")
        XCTAssertEqual(log.filter { $0.hasPrefix("GET /changing.pdf") }.count, 2)
        let before = documentRequests
        let a = try await read(first)
        let b = try await read(second)
        XCTAssertEqual(a.bytes, try data("a.pdf"))
        XCTAssertEqual(b.bytes, try data("b.pdf"))
        XCTAssertEqual(documentRequests, before)
    }

    func testAnAddressNeverLoadedIsNotHeldAndNothingIsRequested() async throws {
        let tab = try await open("/plain.pdf")
        _ = tab.evaluate("history.replaceState(null, '', '/never-loaded.pdf'); 1")
        let before = documentRequests
        let got = await failure(tab)
        XCTAssertEqual(got, .notHeld(detail: "TypeError"))
        XCTAssertEqual(documentRequests, before)
    }

    func testAnHTMLPageIsRefusedWithItsType() async throws {
        let tab = try await open("/plain.html", type: "text/html")
        let before = documentRequests
        let got = await failure(tab)
        XCTAssertEqual(got, .notPDF(contentType: "text/html"))
        XCTAssertEqual(documentRequests, before)
    }

    func testTextPDFIsRead() async throws {
        let tab = try await open("/text.pdf", type: "text/pdf")
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, try data("plain.pdf"))
    }

    /// The one thing the site can see: the browser sends the report itself, with the full address.
    func testAReportingPolicyBlocksTheReadAndTheBrowserReportsIt() async throws {
        let tab = try await open("/csp.pdf?X-Amz-Signature=SECRET")
        let before = documentRequests
        let got = await failure(tab)
        XCTAssertEqual(got, .notHeld(detail: "TypeError"))
        XCTAssertEqual(documentRequests, before, "no request for the document")
        for _ in 0..<20 where !log.contains(where: { $0.hasPrefix("POST /report") }) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(log.contains { $0.hasPrefix("POST /report") && $0.contains("SECRET") },
                      "the README says a report goes out with the full address: \(log)")
    }

    /// The limit the README states: the file is what the tab holds, and nothing says it is all the server has.
    /// A PDF with an incremental update, cut where the first revision ends, is a complete PDF with fewer pages.
    func testAPDFCutAtAnEarlierRevisionIsSavedAsTheTabHoldsIt() async throws {
        let first = Self.manyPages(3, bytesEach: 80_000)
        let startxref = first.range(of: Data("startxref".utf8), options: .backwards)!.lowerBound
        let previous = Int(String(decoding: first[startxref...].dropFirst(10).prefix { $0 != 0x0A }, as: UTF8.self))!
        var full = first
        let replaced = full.count
        full += Data("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 /Touched true >>\nendobj\n".utf8)
        let xref = full.count
        full += Data(String(format: "xref\n2 1\n%010d 00000 n \ntrailer\n<< /Size 9 /Root 1 0 R /Prev %d >>\nstartxref\n%d\n%%%%EOF\n", replaced, previous, xref).utf8)
        try full.write(to: root.appendingPathComponent("revision.pdf"))
        try Data("\(first.count)".utf8).write(to: root.appendingPathComponent("revision-cut"))
        let tab = try await open("/revision.pdf")
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, first, "the tab holds what the server sent, not the whole file")
        let out = root.appendingPathComponent("revision-out.pdf")
        let published = try TabPDFReader.publish(result, to: out.path, force: false, stagingRoot: root)
        XCTAssertEqual(published.pages, 3)
        print("MEASURED revision: \(first.count) of \(full.count) bytes, saved with exit 0")
    }

    /// WebKit answered 200 with the part it received. The page check is what stops it.
    func testATruncatedDocumentDoesNotPublish() async throws {
        let tab = try await open("/short.pdf")
        let out = root.appendingPathComponent("short-out.pdf")
        do {
            let result = try await read(tab)
            print("MEASURED short: answered \(result.bytes.count) of \(try data("plain.pdf").count) bytes")
            XCTAssertThrowsError(try TabPDFReader.publish(result, to: out.path, force: false, stagingRoot: root)) { error in
                guard case SafariBrowserError.pdfCache(.unreadablePDF) = error else { return XCTFail("\(error)") }
            }
        } catch let SafariBrowserError.savePDF(failure) {
            print("MEASURED short: refused in the page: \(failure)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testADocumentStillLoadingSaysSoAndIsReadableOnceLoaded() async throws {
        let tab = Tab()
        tab.page.forced = { [tab] js in tab.evaluate(js) }
        tabs.append(tab)
        let url = base + "/drip.pdf"
        await MainActor.run { tab.load(url) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let early = await failure(tab)
        print("MEASURED drip while loading: \(String(describing: early))")
        XCTAssertEqual(early, .notScriptable)
        for _ in 0..<80 {
            if tab.evaluate("document.contentType") == "application/pdf" { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let result = try await read(tab)
        XCTAssertEqual(result.bytes, try data("drip.pdf"))
    }

    func testFiftyMegabytesComeBackExactly() async throws {
        let bytes = TabPDFFixture.pdf(padding: 50 * 1024 * 1024)
        try bytes.write(to: root.appendingPathComponent("big.pdf"))
        let tab = try await open("/big.pdf")
        let before = documentRequests
        let started = ContinuousClock.now
        let result = try await read(tab)
        print("MEASURED 50 MB in \(ContinuousClock.now - started) (WKWebView, not do JavaScript)")
        XCTAssertEqual(result.bytes, bytes)
        XCTAssertEqual(documentRequests, before)
    }

    /// Pages that are really referenced, so that `qpdf --linearize` keeps them.
    private static func manyPages(_ count: Int, bytesEach: Int) -> Data {
        var objects: [Data] = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)]
        let kids = (0..<count).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(count) >>".utf8))
        let content = Data(String(repeating: "q Q\n", count: bytesEach / 4).utf8)
        for i in 0..<count {
            objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents \(4 + 2 * i) 0 R >>".utf8))
            objects.append(Data("<< /Length \(content.count) >>\nstream\n".utf8) + content + Data("\nendstream".utf8))
        }
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

    func testALinearizedPDFOverByteRangesComesBackWhole() async throws {
        let qpdf = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(qpdf == nil, "qpdf makes the linearized fixture")
        let plain = root.appendingPathComponent("big-plain.pdf")
        try Self.manyPages(200, bytesEach: 100_000).write(to: plain)
        let linearize = Process()
        linearize.executableURL = URL(fileURLWithPath: qpdf!)
        linearize.arguments = ["--linearize", "--compress-streams=n", "--object-streams=disable", "--warning-exit-0",
                               plain.path, root.appendingPathComponent("ranged.pdf").path]
        try linearize.run()
        linearize.waitUntilExit()
        XCTAssertEqual(linearize.terminationStatus, 0)
        let size = try data("ranged.pdf").count
        XCTAssertGreaterThan(size, 10_000_000, "qpdf dropped the pages, so there is nothing to ask ranges of")
        let tab = try await open("/ranged.pdf")
        var settled = documentRequests
        while true {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if documentRequests == settled { break }
            settled = documentRequests
        }
        let ranges = log.filter { $0.contains("/ranged.pdf bytes=") }.count
        print("MEASURED ranged: \(size) bytes, \(ranges) range request(s) while displaying")
        try XCTSkipIf(ranges == 0, "WebKit asked for no range here, so this measured nothing about ranges")
        do {
            let result = try await read(tab)
            XCTAssertEqual(result.bytes, try data("ranged.pdf"), "a partial answer would have to be refused, not returned")
            print("MEASURED ranged: saved whole")
        } catch let SafariBrowserError.savePDF(failure) {
            print("MEASURED ranged: refused: \(failure)")
        }
        XCTAssertEqual(documentRequests, settled, "no request while reading")
    }
}
