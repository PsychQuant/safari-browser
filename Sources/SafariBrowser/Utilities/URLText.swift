import Foundation

/// Showing URLs of open tabs in error and warning text (#227).
///
/// A query string can be a credential: signed links keep their signature there, and an OAuth
/// callback keeps its code or token in the query or fragment. The listings that exist to help a
/// person pick a `--url` substring or a tab position need scheme, host and path, so that is what
/// they show, with a marker where something was removed. `documents` is different — it is what a
/// person runs on purpose to see the URLs — and prints them in full.
///
/// This is applied where the strings are BUILT, not where they are rendered: a daemon's wire
/// error and log line print the error's payload (`"\(error)"`), not its `errorDescription`, so a
/// redaction in the rendering would leave the payload — and everything that prints it — carrying
/// the full URL. It is idempotent, so applying it again at a rendering is harmless.
enum URLText {
    /// The most scalars of scheme, host and path that are shown (a `?…` or `#…` marker comes after
    /// them). A tab URL is unbounded and a listing has one line per tab, so what is kept is a
    /// bounded prefix, ending in `…` when it was cut.
    static let maxLength = 200

    /// Schemes whose URL is a payload, not an address: everything after the colon is shown as `…`.
    private static let payloadSchemes: Set<String> = ["data", "javascript"]

    /// Shows scheme, host and path, with these removed, each marked where it was:
    ///
    /// - everything from the first `?` or `#` (`?…` when a query was removed, `#…` when only a
    ///   fragment was; a `?` after the `#` belongs to the fragment);
    /// - the credentials of an authority, `user:pass@` → `…@`, including one inside the path
    ///   (`https://proxy.example/https://user:pass@host/`);
    /// - path parameters, `;jsessionid=…` → `;…`, up to the next `/`;
    /// - the whole content of a `data:` or `javascript:` URL (`data:…`);
    /// - whatever follows the first `maxLength` scalars.
    ///
    /// Delimiters are found among Unicode scalars, not `Character`s: a combining mark after `?`
    /// makes one grapheme cluster that is not equal to `?`, and a search by `Character` would
    /// miss the query it was meant to cut. There is no requirement that the text look like a
    /// hierarchical URL, so `about:blank#x` is cut the same way.
    ///
    /// What is NOT recognisable as a secret stays: a token that is a path segment
    /// (`/reset/<token>`) is indistinguishable from a path that identifies the tab.
    static func redactURL(_ url: String) -> String {
        // Applied until it stops changing (at most a few times), so that the result is a fixed
        // point: the cap can cut inside a `;…` marker or drop the `://` a step relied on, and one
        // more pass would then change the text again.
        var current = redactOnce(url)
        for _ in 0..<4 {
            let next = redactOnce(current)
            if next == current { break }
            current = next
        }
        return current
    }

    private static func redactOnce(_ url: String) -> String {
        var scalars = Array(url.unicodeScalars)
        if let scheme = scheme(of: scalars), payloadSchemes.contains(scheme.lowercased()) {
            return scheme + ":…"
        }
        var marker = ""
        if let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            marker = scalars[cut] == "?" ? "?…" : "#…"
            scalars.removeSubrange(cut...)
        }
        scalars = removingPathParameters(removingUserinfo(scalars))
        if scalars.count > maxLength {
            scalars = Array(scalars[..<(maxLength - 1)]) + ["…"]
        }
        return String(String.UnicodeScalarView(scalars)) + marker
    }

    /// The leading run of a URL up to its first `:`, when it is shaped like a scheme.
    private static func scheme(of scalars: [Unicode.Scalar]) -> String? {
        // A URL parser ignores leading C0 controls and spaces, so `" data:…"` is a data: URL.
        let start = scalars.firstIndex(where: { $0.value > 0x20 }) ?? scalars.count
        guard let colon = scalars[start...].firstIndex(of: ":"), colon > start else { return nil }
        let head = scalars[start..<colon]
        guard let first = head.first, first.properties.isAlphabetic, first.isASCII,
              head.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return String(String.UnicodeScalarView(head))
    }

    /// `scheme://user:pass@host/path` → `scheme://…@host/path`, for every `://` in the text. An
    /// authority ends at the first `/` after its `://`; its credentials end at its last `@`.
    private static func removingUserinfo(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        var position = 0
        while position < scalars.count {
            guard let separator = nextSchemeSeparator(in: scalars, from: position) else {
                output += scalars[position...]
                break
            }
            let authorityStart = separator + 3
            output += scalars[position..<authorityStart]
            let authorityEnd = scalars[authorityStart...].firstIndex(of: "/") ?? scalars.count
            if let at = scalars[authorityStart..<authorityEnd].lastIndex(of: "@") {
                output += ["…", "@"]
                position = at + 1
            } else {
                position = authorityStart
            }
        }
        return output
    }

    private static func nextSchemeSeparator(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        guard scalars.count - start >= 3 else { return nil }
        for index in start...(scalars.count - 3) where scalars[index] == ":" && scalars[index + 1] == "/" && scalars[index + 2] == "/" {
            return index
        }
        return nil
    }

    /// `/app/page;jsessionid=ABC/next` → `/app/page;…/next`: a `;` in the path starts a parameter
    /// that runs to the next `/`. The authority is left alone; a text without one is all path.
    private static func removingPathParameters(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // The outer authority is there only when the text opens with `scheme://`; a `://` further
        // in belongs to a URL inside the path, and everything before it is path.
        var start = 0
        if let separator = nextSchemeSeparator(in: scalars, from: 0), scalars.firstIndex(of: ":") == separator,
           scheme(of: Array(scalars[..<(separator + 1)])) != nil {
            start = scalars[(separator + 3)...].firstIndex(of: "/") ?? scalars.count
        }
        var output = Array(scalars[..<start])
        var index = start
        while index < scalars.count {
            output.append(scalars[index])
            if scalars[index] == ";" {
                output.append("…")
                index += 1
                while index < scalars.count, scalars[index] != "/" { index += 1 }
            } else {
                index += 1
            }
        }
        return output
    }
}

/// A tab URL that cannot be carried unredacted: the only way to make one is from a raw URL, which
/// is redacted on the way in (#227). An error payload that holds one — `targetTabChanged` does —
/// therefore prints only what may be shown, in `"\(error)"` (which a daemon's wire error and log
/// line use) as well as in `errorDescription`, and a producer cannot pass a raw string by mistake:
/// there is no string-literal conversion.
struct RedactedURL: Equatable, Sendable, CustomStringConvertible {
    let text: String
    init(_ raw: String) { text = URLText.redactURL(raw) }
    var description: String { text }
}
