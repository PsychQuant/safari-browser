import AppKit
import WebKit
import XCTest
@testable import SafariBrowser

/// Public WKUIDelegate supplies an owned URL without displaying a chooser.
/// This exercises real WebKit File metadata, not Safari's AX/menu pipeline.
@MainActor
final class NativeUploadWebKitTests: XCTestCase {
    func testRealFileMetadataPassesProductionValidator() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(".upload-webkit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for seconds in [1_700_000_000.001, 1_700_000_000.627, 1_700_000_000.999, -1.999, -1.9995, -0.9995] {
            let file = directory.appendingPathComponent(".檔案 ' café.txt")
            try Data("owned fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            let expected = try UploadCommand.nativeModificationTimeMilliseconds(date)
            let probe = UploadWebKitMetadataProbe(file: file, size: size, milliseconds: expected)
            let text = try await probe.run()
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(result["verdict"] as? String, "OK", "actual WebKit metadata: \(text), expected mtime=\(expected)")
            XCTAssertEqual(result["name"] as? String, file.lastPathComponent)
            XCTAssertEqual((result["size"] as? NSNumber)?.int64Value, size)
            XCTAssertEqual(result["trusted"] as? Bool, true)
        }
    }
    func testPageConsumptionAfterTrustedDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(".upload-consumption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("owned.txt")
        try Data("owned fixture".utf8).write(to: file)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let date = try XCTUnwrap(attrs[.modificationDate] as? Date)
        let expected = try UploadCommand.nativeModificationTimeMilliseconds(date)
        for pageEvent in ["input", "change"] {
        for mutation in ["event.target.value='';", "event.target.replaceWith(event.target.cloneNode());", "history.pushState({},'', '#received');"] {
            let probe = UploadWebKitMetadataProbe(file: file, size: 13, milliseconds: expected, afterSelection: mutation, pageEvent: pageEvent)
            let text = try await probe.run()
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(result["verdict"] as? String, "OK", "page consumption must preserve delivery evidence: \(mutation) → \(text)")
            XCTAssertEqual(result["trusted"] as? Bool, true)
        }
        }
    }

}

@MainActor
private final class UploadWebKitMetadataProbe: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let file: URL
    private let size: Int64
    private let milliseconds: Int64
    private let afterSelection: String
    private let pageEvent: String
    private let nonce = UUID().uuidString
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?

    init(file: URL, size: Int64, milliseconds: Int64, afterSelection: String = "", pageEvent: String = "change") {
        self.file = file; self.size = size; self.milliseconds = milliseconds
        self.afterSelection = afterSelection; self.pageEvent = pageEvent
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(self, name: "result")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.uiDelegate = self; view.navigationDelegate = self
            webView = view
            view.loadHTMLString("<!doctype html><input type=file id=fixture>", baseURL: URL(string: "https://fixture.invalid/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.finish(.failure(NSError(domain: "NativeUploadWebKitTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WebKit did not deliver the owned selection"])))
            }
        }
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        let initialize = NativeUploadScript.initializeJS(selector: "#fixture", nonce: nonce)
        let validate = NativeUploadScript.completionJS(selector: "#fixture", nonce: nonce,
            fileName: file.lastPathComponent, fileSize: size, modificationTimeMilliseconds: milliseconds)
        let script = """
        document.getElementById('fixture').addEventListener('\(pageEvent)', event => { \(afterSelection) });
        if (\(initialize) !== 'OK') throw new Error('initialization failed');
        document.addEventListener('\(pageEvent)', event => {
          const f=event.target.files[0];
          setTimeout(() => window.webkit.messageHandlers.result.postMessage(JSON.stringify({
            verdict:\(validate), trusted:event.isTrusted, name:f.name, size:f.size, lastModified:f.lastModified
          })), 0);
        }, true);
        \(NativeUploadScript.openJS(selector: "#fixture", nonce: nonce))
        """
        view.evaluateJavaScript(script) { [weak self] _, error in
            if let error { self?.finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        completionHandler([file])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else {
            finish(.failure(NSError(domain: "NativeUploadWebKitTests", code: 2))); return
        }
        finish(.success(text))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "result")
        webView?.uiDelegate = nil; webView?.navigationDelegate = nil
        webView = nil
        pending.resume(with: result)
    }
}
