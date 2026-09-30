import Foundation

/// Showing URLs of open tabs in error and warning text (#227).
///
/// A query string can be a credential: signed links keep their signature there. The listings
/// that exist to help a person pick a `--url` substring need scheme, host and path, so that is
/// what they show, with a marker where something was removed. `documents` is different — it is
/// what a person runs on purpose to see the URLs — and prints them in full.
enum URLText {
    /// Cuts a URL at its first `?` or `#`, leaving `?…` when a query was removed and `#…` when
    /// only a fragment was (a `?` after the `#` belongs to the fragment).
    ///
    /// The delimiter is found among Unicode scalars, not `Character`s: a combining mark after
    /// `?` makes one grapheme cluster that is not equal to `?`, and a search by `Character`
    /// would miss the query it was meant to cut.
    static func redactURL(_ url: String) -> String {
        let scalars = url.unicodeScalars
        guard let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(scalars[..<cut]) + (scalars[cut] == "?" ? "?…" : "#…")
    }

    /// Applies `redactURL` to every whitespace-separated token of `text` that contains `://`.
    /// Everything else — labels such as `window 1 [Work]:`, counts, `(unknown)`, and all the
    /// whitespace between tokens — is returned exactly as it was. The listings the resolvers
    /// build all have the shape `<label>: <URL>[ <suffix>]`, so a token is the right unit.
    static func redactingURLs(in text: String) -> String {
        var output = String.UnicodeScalarView()
        var token = String.UnicodeScalarView()
        func flush() {
            let word = String(token)
            output.append(contentsOf: (containsSchemeSeparator(word) ? redactURL(word) : word).unicodeScalars)
            token = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                flush()
                output.append(scalar)
            } else {
                token.append(scalar)
            }
        }
        flush()
        return String(output)
    }

    /// `://` located in the scalars, for the same reason as above: `/` plus a combining mark is
    /// not the Character `/`.
    private static func containsSchemeSeparator(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for index in 0...(scalars.count - 3)
        where scalars[index] == ":" && scalars[index + 1] == "/" && scalars[index + 2] == "/" {
            return true
        }
        return false
    }
}
