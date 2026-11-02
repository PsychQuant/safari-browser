import Foundation

/// Why `save-pdf` stopped (#338). A closed list; none of these falls back to a request.
enum SavePDFFailure: Equatable, Sendable {
    /// The tab's document is something else, for example an HTML page embedding a PDF.
    case notPDF(contentType: String)
    /// A service worker controls the tab, and its answer could come from the network.
    case serviceWorker
    /// The `only-if-cached` fetch rejected. WebKit no longer holds the document or the page's policy
    /// blocked the read; the page cannot tell the two apart (both are a `TypeError`). `detail` is the
    /// error's name, never its message.
    case notHeld(detail: String)
    /// What WebKit holds is not a complete response: an error, or a byte range (206).
    case badStatus(code: Int)
    /// The answer is a redirect, or for another URL than the tab's address.
    case differentResponse
    /// The fetch answered and a later step in the page failed (reading the body, encoding it).
    case readFailed(detail: String)
    /// Over `TabPDFReader.maxBytes`, reported before the bytes are encoded.
    case tooLarge(bytes: Int)
    /// Another page is at this address than the one named when the command started.
    case tabChanged
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
            return "A service worker controls this tab and its answer could come from the network, so nothing was read. Save this PDF by hand."
        case .notHeld(let detail):
            return "Could not read the PDF from the tab (\(t(detail))): WebKit no longer holds the document, or the page's policy blocked the read. No request was sent. Display the PDF again, or save it by hand."
        case .badStatus(let code):
            return "What WebKit holds for this tab is an HTTP \(code) response, so it was not saved. No request was sent."
        case .differentResponse:
            return "What WebKit holds for this address is a redirect or the answer for another URL, so it was not saved. No request was sent."
        case .readFailed(let detail):
            return "WebKit answered, but the tab could not prepare the document (\(t(detail))), so nothing was saved. No request was sent."
        case .tooLarge(let bytes):
            return "The PDF is \(bytes) bytes, over the \(TabPDFReader.maxBytes) byte limit of save-pdf. Nothing was written."
        case .tabChanged:
            return "Another page is at that tab's position than when the command started, so nothing was read. No request was sent. Run the command again."
        case .bytesNotPDF:
            return "What WebKit holds for this tab's address does not start with %PDF-, so nothing was saved. No request was sent."
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
