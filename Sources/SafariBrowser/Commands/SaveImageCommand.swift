import ArgumentParser
import Foundation

/// #31: download a DOM element's raw resource to disk.
///
/// Complementary to `screenshot --element` (#30): that produces lossy
/// rasterized PNG via AX+CoreGraphics; this produces lossless original
/// bytes via JS+HTTP. Does NOT require Accessibility permission.
struct SaveImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save-image",
        abstract: "Download a DOM element's raw resource (img/video/audio/picture src or inline SVG outerHTML)"
    )

    @Argument(help: "Output file path; bytes are written verbatim with no extension inference")
    var path: String

    @Option(name: .long, help: "CSS selector for the element (required; light DOM only)")
    var element: String

    @Option(name: .customLong("element-index"), help: "1-indexed match picker for --element (disambiguates multi-match)")
    var elementIndex: Int?

    @Option(name: .long, help: "Which resource attribute to read: currentSrc (default) / src / poster")
    var track: String = "currentSrc"

    @Flag(name: .long, help: "Fetch via Safari's own fetch() to inherit cookies/session (10 MB hard cap)")
    var withCookies = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        if let idx = elementIndex, idx < 1 {
            throw ValidationError("--element-index must be >= 1 (got \(idx))")
        }
        if SafariBridge.ResourceTrack(rawValue: track) == nil {
            throw ValidationError("--track must be one of: currentSrc, src, poster (got \"\(track)\")")
        }
    }

    func run() async throws {
        let trackEnum = SafariBridge.ResourceTrack(rawValue: track) ?? .currentSrc
        let (docTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()

        // Resolve the target window (validates target options + raises
        // background-tab error if applicable — reuse #26 machinery).
        // We don't actually need the window handle for save-image since
        // we only eval JS on the document, but running the resolver
        // surfaces targeting errors early.
        _ = try await SafariBridge.resolveNativeTarget(from: docTarget)

        // Resolve element → ElementResource (throws element errors)
        let resource = try await SafariBridge.resolveElementResource(
            selector: element,
            target: docTarget,
            track: trackEnum,
            elementIndex: elementIndex
        )

        // Dispatch based on resource kind
        switch resource {
        case .inlineSVG(let outerHTML):
            try writeSVG(outerHTML, to: path)

        case .url(let urlString):
            try await downloadURL(urlString, docTarget: docTarget)
        }
    }

    /// Inline SVG: serialize outerHTML to UTF-8 at user's path.
    /// No HTTP request, no network, no MIME inference.
    private func writeSVG(_ outerHTML: String, to path: String) throws {
        guard let data = outerHTML.data(using: .utf8) else {
            throw SafariBrowserError.downloadFailed(
                url: "(inline SVG)",
                statusCode: nil,
                reason: "could not encode SVG outerHTML as UTF-8"
            )
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
    }

    /// URL dispatch by scheme:
    ///   - data:   → Foundation decode, no network
    ///   - http:   → URLSession + stderr warn
    ///   - https:  → URLSession
    ///   - --with-cookies → JS fetch bridge (overrides scheme choice for http/https)
    ///   - other   → unsupportedURLScheme fail-closed
    private func downloadURL(_ urlString: String, docTarget: SafariBridge.TargetDocument) async throws {
        let scheme = extractScheme(urlString)

        // data: URLs bypass URLSession regardless of --with-cookies
        if scheme == "data" {
            let bytes = try decodeDataURL(urlString)
            try writeBytes(bytes, to: path)
            return
        }

        // Supported network schemes: http, https
        guard scheme == "http" || scheme == "https" else {
            throw SafariBrowserError.unsupportedURLScheme(url: urlString, scheme: scheme)
        }

        // HTTP stderr warn (non-blocking)
        if scheme == "http" {
            FileHandle.standardError.write(Data(
                "⚠️  Downloading over http:// — contents and cookies traverse cleartext\n".utf8
            ))
        }

        let bytes: Data
        if withCookies {
            bytes = try await SafariBridge.fetchResourceWithCookies(
                url: urlString, target: docTarget
            )
        } else {
            bytes = try await fetchViaURLSession(urlString, docTarget: docTarget)
        }
        try writeBytes(bytes, to: path)
    }

    /// URLSession fetch with Safari-equivalent Referer + User-Agent.
    /// Drops Referer on cross-origin redirect (strict-origin policy).
    private func fetchViaURLSession(
        _ urlString: String,
        docTarget: SafariBridge.TargetDocument
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw SafariBrowserError.downloadFailed(
                url: urlString, statusCode: nil, reason: "malformed URL"
            )
        }

        // Fetch Referer (document URL) and User-Agent from Safari JS side.
        let referer = (try? await SafariBridge.doJavaScript("document.URL", target: docTarget))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let userAgent = (try? await SafariBridge.doJavaScript("navigator.userAgent", target: docTarget))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        var request = URLRequest(url: url)
        if !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let delegate = CrossOriginRefererDropDelegate(originalReferer: referer)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SafariBrowserError.downloadFailed(
                url: urlString, statusCode: nil, reason: "non-HTTP response"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SafariBrowserError.downloadFailed(
                url: urlString,
                statusCode: httpResponse.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        return data
    }

    /// Write bytes to user path verbatim. Overwrites silently.
    /// No MIME inference, no extension check, no Content-Type reading.
    private func writeBytes(_ bytes: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try bytes.write(to: url)
    }

    /// Extract URL scheme (lowercased) without relying on URLComponents.
    /// data:, blob:, javascript: URLs often fail URLComponents parsing
    /// but still start with `<scheme>:` — split on first colon.
    internal static func extractSchemeFrom(_ urlString: String) -> String {
        if let colon = urlString.firstIndex(of: ":") {
            return String(urlString[..<colon]).lowercased()
        }
        return ""
    }

    private func extractScheme(_ urlString: String) -> String {
        Self.extractSchemeFrom(urlString)
    }

    /// Decode a `data:<mime>;base64,<payload>` URL into raw bytes.
    /// Also handles `data:<mime>,<payload>` (non-base64, percent-encoded).
    internal static func decodeDataURL(_ urlString: String) throws -> Data {
        // Strip `data:` prefix
        guard urlString.hasPrefix("data:") else {
            throw SafariBrowserError.downloadFailed(
                url: urlString, statusCode: nil, reason: "not a data URL"
            )
        }
        let afterPrefix = String(urlString.dropFirst(5))

        // Split on first comma: `<mime>[;base64],<payload>`
        guard let commaIdx = afterPrefix.firstIndex(of: ",") else {
            throw SafariBrowserError.downloadFailed(
                url: urlString, statusCode: nil, reason: "malformed data URL (no comma)"
            )
        }
        let metadata = afterPrefix[..<commaIdx]
        let payload = String(afterPrefix[afterPrefix.index(after: commaIdx)...])

        if metadata.contains(";base64") {
            guard let decoded = Data(base64Encoded: payload) else {
                throw SafariBrowserError.downloadFailed(
                    url: urlString, statusCode: nil, reason: "invalid base64 payload in data URL"
                )
            }
            return decoded
        } else {
            // Percent-decoded text data URL
            guard let decoded = payload.removingPercentEncoding?.data(using: .utf8) else {
                throw SafariBrowserError.downloadFailed(
                    url: urlString, statusCode: nil, reason: "invalid percent-encoded payload in data URL"
                )
            }
            return decoded
        }
    }

    private func decodeDataURL(_ urlString: String) throws -> Data {
        try Self.decodeDataURL(urlString)
    }
}

/// #31: URLSession delegate that drops the `Referer` header on
/// cross-origin redirects. Matches browser `strict-origin-when-cross-origin`
/// semantics — avoids leaking document URL to third-party hosts.
private final class CrossOriginRefererDropDelegate: NSObject, URLSessionTaskDelegate {
    let originalReferer: String

    init(originalReferer: String) {
        self.originalReferer = originalReferer
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if SaveImageCommand.isCrossOrigin(from: originalReferer, to: request.url) {
            redirected.setValue(nil, forHTTPHeaderField: "Referer")
        } else if !originalReferer.isEmpty {
            redirected.setValue(originalReferer, forHTTPHeaderField: "Referer")
        }
        completionHandler(redirected)
    }
}

extension SaveImageCommand {
    /// Origin = scheme + host + port. Returns true iff the two URLs
    /// differ in any of those three components. Used by the redirect
    /// delegate to decide whether to drop the Referer header.
    /// Exposed for unit testing.
    static func isCrossOrigin(from fromURLString: String, to toURL: URL?) -> Bool {
        guard let to = toURL else { return true }
        guard let from = URL(string: fromURLString) else { return true }
        if (from.scheme ?? "").lowercased() != (to.scheme ?? "").lowercased() { return true }
        if (from.host ?? "").lowercased() != (to.host ?? "").lowercased() { return true }
        // port: nil == default port for scheme; treat missing as equal
        // only when both are missing (same host implies same default).
        if from.port != to.port { return true }
        return false
    }
}
