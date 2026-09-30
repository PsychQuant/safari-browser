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
    /// Shows scheme, host and path: everything from the first `?` or `#` is cut, leaving `?…`
    /// when a query was removed and `#…` when only a fragment was (a `?` after the `#` belongs to
    /// the fragment), and the credentials of an authority (`user:pass@`) are replaced by `…@`.
    ///
    /// Delimiters are found among Unicode scalars, not `Character`s: a combining mark after `?`
    /// makes one grapheme cluster that is not equal to `?`, and a search by `Character` would
    /// miss the query it was meant to cut. There is no requirement that the text look like a
    /// hierarchical URL, so `about:blank#x` and `data:text/plain,a?b` are cut the same way.
    static func redactURL(_ url: String) -> String {
        var scalars = Array(url.unicodeScalars)
        var marker = ""
        if let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            marker = scalars[cut] == "?" ? "?…" : "#…"
            scalars.removeSubrange(cut...)
        }
        return String(String.UnicodeScalarView(removingUserinfo(scalars))) + marker
    }

    /// `scheme://user:pass@host/path` → `scheme://…@host/path`. The authority ends at the first
    /// `/` after `://`; the credentials end at its last `@`.
    private static func removingUserinfo(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard scalars.count >= 3 else { return scalars }
        var separator: Int?
        for index in 0...(scalars.count - 3) where scalars[index] == ":" && scalars[index + 1] == "/" && scalars[index + 2] == "/" {
            separator = index
            break
        }
        guard let separator else { return scalars }
        let authorityStart = separator + 3
        let authorityEnd = scalars[authorityStart...].firstIndex(of: "/") ?? scalars.count
        guard let at = scalars[authorityStart..<authorityEnd].lastIndex(of: "@") else { return scalars }
        return Array(scalars[..<authorityStart]) + Array("…@".unicodeScalars) + Array(scalars[(at + 1)...])
    }
}
