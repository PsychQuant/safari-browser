import Foundation

/// Why `save-pdf` stopped (#338). A closed list; none of these falls back to another request.
enum SavePDFFailure: Equatable, Sendable {
    /// The tab's document is something else, for example an HTML page embedding a PDF.
    case notPDF(contentType: String)
    /// A service worker controls the tab and `--allow-service-worker` was not given (#390, comment 7201248012):
    /// refused before the fetch, so nothing was read and the service worker saw nothing.
    case serviceWorker
    /// The `only-if-cached` fetch rejected. WebKit does not hold the whole document (it was dropped, or the
    /// load stopped) or the page's policy blocked the read; the page cannot tell these apart (all are a
    /// `TypeError`). `detail` is the error's name, never its message. A read made with `--allow-service-worker` on a
    /// tab a service worker controls goes to the service worker when WebKit does not hold the document, so this
    /// and the failures after it name that exception.
    case notHeld(detail: String)
    /// The fetch answered with something other than 200. On WebKit a PDF document answers 200 whatever the
    /// server sent, so this is for an engine that does not.
    case badStatus(code: Int)
    /// The fetch answered and a later step in the page failed (reading the body, encoding it).
    case readFailed(detail: String)
    /// Over `TabPDFReader.maxBytes`, reported before the bytes are encoded.
    case tooLarge(bytes: Int)
    /// The start script did not run: the document is still loading, or its policy forbids scripts.
    case notScriptable
    /// What was read does not start with `%PDF-`.
    case bytesNotPDF
    /// The slot is gone: the page was replaced since the read started.
    case pageReplaced
    /// The page did not finish in time.
    case timedOut(seconds: Double)
    /// A reply outside the closed format, a transfer that did not check out, or a byte count that differs.
    case damagedReply(detail: String)
    /// The private temporary copy could not be written.
    case stagingFailed(detail: String)

    var message: String {
        func t(_ text: String) -> String { TerminalText.escaped(text) }
        switch self {
        case .notPDF(let contentType):
            return "The tab's document is '\(t(contentType))', not a PDF. save-pdf reads a tab that displays a PDF itself; a PDF embedded in an HTML page is not covered."
        case .serviceWorker:
            return "A service worker controls this tab, so nothing was read and no request was sent. To read it anyway, run again with --allow-service-worker: the read is the same, and when WebKit no longer holds the document the service worker receives it and can answer from the network."
        case .notHeld(let detail):
            return "Could not read the PDF from the tab (\(t(detail))): WebKit does not hold the whole document (it was dropped, or the load stopped), or the page's policy blocked the read. No request for the document was sent, unless --allow-service-worker was given and a service worker controls this tab: then the read may have gone to the service worker, which can answer from the network. Display the PDF again, or save it by hand."
        case .badStatus(let code):
            return "The tab answered with HTTP \(code), so nothing was saved. No request was sent, unless --allow-service-worker was given and a service worker controls this tab: then the read may have gone to the service worker, which can answer from the network."
        case .readFailed(let detail):
            return "WebKit answered, but the tab could not prepare the document (\(t(detail))), so nothing was saved. No request was sent, unless --allow-service-worker was given and a service worker controls this tab: then the read may have gone to the service worker, which can answer from the network."
        case .tooLarge(let bytes):
            return "The PDF is \(bytes) bytes, over the \(TabPDFReader.maxBytes) byte limit of save-pdf. Nothing was written."
        case .notScriptable:
            return "The tab is not running scripts: it is still loading, or its policy forbids them. Nothing was read and no request was sent. Run this again when it has loaded, or save the PDF by hand."
        case .bytesNotPDF:
            return "What the tab holds does not start with %PDF-, so nothing was saved. No request was sent, unless --allow-service-worker was given and a service worker controls this tab: then the read may have gone to the service worker, which can answer from the network."
        case .pageReplaced:
            return "The tab's page was replaced during the read, so nothing was saved."
        case .timedOut(let seconds):
            return "The tab did not finish reading the PDF within \(seconds) seconds, so nothing was saved."
        case .damagedReply(let detail):
            return "The reply from the tab was damaged (\(t(detail))), so nothing was saved."
        case .stagingFailed(let detail):
            return "Could not write the temporary copy (\(t(detail))), so nothing was saved."
        }
    }
}
