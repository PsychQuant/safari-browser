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
    /// The sentence that every message listing URLs carries (#227), so that two entries that differ
    /// only in a part that is not shown do not read as a repeated line.
    static let shortenedNote = "URLs are shown shortened — a query, fragment, credentials, path parameters or a long tail is replaced by `…`; `safari-browser documents` prints them in full."

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
    /// (`/reset/<token>`) is indistinguishable from a path that identifies the tab. So does the
    /// userinfo of a URL inside a path that is spelled with fewer than two slashes after its scheme
    /// (`https:user:pw@host`): Safari spells its own tab URLs canonically, and an embedded URL is
    /// path text that no one has normalised.
    ///
    /// A URL parser removes ASCII tab, LF and CR from anywhere in its input, so this does too, first
    /// of all: a scheme or a `//` broken up by them is one, and what is shown has none of them.
    /// Where a parser and a plain reading of the text still differ (a backslash for a slash, extra
    /// slashes), each rule below takes the reading that removes more, with one exception that goes
    /// the other way on purpose: the authority whose path parameters are removed starts after
    /// exactly two slashes, so that in `file:///app;jsessionid=…` the first segment is path.
    static func redactURL(_ url: String) -> String {
        // The cap can cut inside a `;…` marker or drop the `://` a step relied on, and one more pass
        // would then change the text again, so the pass is repeated until the text stops changing.
        // At most five applications are made; in the inputs tried the second is the last that
        // changes anything, but that is not proved, and `testRedactionIsIdempotent` and the sweep
        // check the result rather than this bound.
        var current = redactOnce(url)
        for _ in 0..<4 {
            let next = redactOnce(current)
            if next == current { break }
            current = next
        }
        return current
    }

    private static func redactOnce(_ url: String) -> String {
        var scalars = Array(url.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" })
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

    /// `scheme://user:pass@host/path` → `scheme://…@host/path`, for every authority in the text. An
    /// authority starts after a `:` that is followed by two or more slashes or backslashes (a URL
    /// parser reads a backslash as a slash and skips extra ones, so `https:////u:p@host/` has the
    /// authority `u:p@host`). It ends at the first `/` after that, and its credentials end at its
    /// last `@`. A backslash does not end it here: when the readings differ, the longer authority
    /// is the one that redacts more.
    private static func removingUserinfo(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // Where the next `/` is, and where the last `@` at or before each index is, so that finding
        // an authority's end and its credentials is a lookup: a text made of many authorities with no
        // `/` between them is then still linear.
        let count = scalars.count
        var nextSlash = [Int](repeating: count, count: count + 1)
        var lastAt = [Int](repeating: -1, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) { nextSlash[index] = scalars[index] == "/" ? index : nextSlash[index + 1] }
        for index in 0..<count { lastAt[index] = scalars[index] == "@" ? index : (index > 0 ? lastAt[index - 1] : -1) }
        var output: [Unicode.Scalar] = []
        var position = 0
        while position < count {
            guard let authority = nextAuthority(in: scalars, from: position) else {
                output += scalars[position...]
                break
            }
            output += scalars[position..<authority.start]
            let authorityEnd = nextSlash[authority.start]
            if authorityEnd > authority.start, lastAt[authorityEnd - 1] >= authority.start {
                output += ["…", "@"]
                position = lastAt[authorityEnd - 1] + 1
            } else {
                position = authority.start
            }
        }
        return output
    }

    private static func isSlash(_ scalar: Unicode.Scalar) -> Bool { scalar == "/" || scalar == "\\" }

    /// The next `:` at or after `start` that is followed by two or more slashes or backslashes:
    /// where it is, and where the authority begins (after all of those). Linear: a run of slashes
    /// is skipped once, and the search continues after it.
    private static func nextAuthority(in scalars: [Unicode.Scalar], from start: Int) -> (colon: Int, start: Int)? {
        var index = start
        while index < scalars.count {
            if scalars[index] == ":" {
                var end = index + 1
                while end < scalars.count, isSlash(scalars[end]) { end += 1 }
                if end - (index + 1) >= 2 { return (index, end) }
            }
            index += 1
        }
        return nil
    }

    /// `/app/page;jsessionid=ABC/next` → `/app/page;…/next`: a `;` in the path starts a parameter
    /// that runs to the next `/`. The authority is left alone; a text without one is all path.
    private static func removingPathParameters(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // The outer authority is there only when the text opens with `scheme://`; a `://` further
        // in belongs to a URL inside the path, and everything before it is path. It starts after
        // exactly two slashes (a third one makes it empty: `file:///app;x` has a path `/app;x`) and
        // a backslash ends it: the text after it is the path, and its parameters are removed.
        var start = 0
        if let authority = nextAuthority(in: scalars, from: 0), scalars.firstIndex(of: ":") == authority.colon,
           scheme(of: Array(scalars[...authority.colon])) != nil {
            start = scalars[(authority.colon + 3)...].firstIndex(where: isSlash) ?? scalars.count
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
