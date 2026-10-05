import Foundation

/// A call's own place in the page for a result that does not come back inline (#190).
///
/// A result larger than one `do JavaScript` answer (`js --large`, a result over
/// `JSWrapper.inlineResultLimit`, `get text`, `snapshot`, an `exec` step) is parked in the page and
/// read back in chunks. It used to be parked under two fixed names, so two calls on one page shared
/// them: a call could read what another had left, and nothing told it so. Now every call parks its
/// result in a slot named for that call alone.
///
/// The slot is one page object, `window.<key> = { text, len, err }`, so a call has one name to clean
/// up and one name to be wrong about.
///
/// The name is not a secret and not an authentication boundary: a script in the same page can read it.
/// It keeps *calls of this CLI* from reading one another's results, which is what #190 observed.
struct ResultSlot: Equatable, Sendable {
    static let keyPrefix = "__sbr_"

    /// UTF-16 units per chunk read. Unchanged from the fixed-name chunked read (256 KiB).
    static let chunkSize = 262_144

    /// The slot's property name on `window`. Only ever built by `make()` or `init?(pageKey:)`, so it is
    /// always a plain identifier and can be pasted into a script.
    let key: String

    /// A slot named by the CLI. The `--large` path needs the name before its code runs, to read the
    /// error the code recorded and to tell "the code never ran" from "the code found nothing".
    static func make() -> ResultSlot {
        ResultSlot(validKey: keyPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    }

    /// A slot named by the page, from the reply of an inline wrapper (`SB1:BIG:<len>:<key>`). The inline
    /// wrapper cannot carry a per-call name without making every `js` script unique, which would defeat the
    /// daemon's compile cache for the most common command, so the page picks the name and says it.
    /// Refused unless it is exactly the shape the wrapper builds, because the name goes into scripts.
    init?(pageKey: String) {
        guard Self.isValid(pageKey) else { return nil }
        self.key = pageKey
    }

    private init(validKey: String) { self.key = validKey }

    /// `__sbr_` followed by 8 to 64 of `[0-9a-z]`.
    static func isValid(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix) else { return false }
        let rest = key.utf8.dropFirst(keyPrefix.utf8.count)
        return (8...64).contains(rest.count)
            && rest.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) }
    }

    private var ref: String { "window.\(key)" }

    // MARK: - scripts

    /// Marks the slot as "nothing stored yet": its `len` is undefined, which `lengthScript` reports as
    /// `JSWrapper.lenUnsetSentinel`. A page that navigated away has no slot at all, which reads the same.
    var presetScript: String { "\(ref) = {}" }

    /// Evaluate `expression`, make it text, replace a lone surrogate with U+FFFD, and park it.
    ///
    /// The slot object is made BEFORE the expression is evaluated, so an expression that throws leaves
    /// a slot with no `len` (the "never ran or threw" sentinel) and an expression that does not parse
    /// leaves no slot or an untouched preset. `toWellFormed()` because osascript drops a lone
    /// surrogate without a word (#255); U+FFFD has the same length and survives. A Safari without
    /// `toWellFormed` keeps the lone surrogate and the chunk read reports the length mismatch.
    ///
    /// The user's expression is an ARGUMENT of the function that stores it, so it is evaluated where
    /// `do JavaScript` runs it, not inside a function that declares variables of its own: a `var s` or
    /// `var r` there would shadow a page global named `s` or `r` and the expression would read
    /// `undefined` without a word.
    func storeScript(_ expression: String) -> String {
        """
        (\(ref) = \(ref) || {}, (function(r){ if (typeof r.toWellFormed === 'function') { r = r.toWellFormed(); } var s = \(ref); s.text = r; s.len = r.length; })('' + (
        \(expression)
        )))
        """
    }

    /// The length as text, or `JSWrapper.lenUnsetSentinel` when the slot is missing or nothing was stored.
    var lengthScript: String {
        "(function(){ var s = \(ref); return s ? '' + s.len : 'undefined'; })()"
    }

    /// The error a `--large` wrapper recorded, as `E:<text>` (the text may be empty), or
    /// `JSWrapper.lenUnsetSentinel` when nothing was recorded. The prefix is what tells an error whose message is
    /// empty (`throw ''`) from no error.
    var errorScript: String {
        "(function(){ var s = \(ref); return s && s.err !== undefined ? 'E:' + s.err : 'undefined'; })()"
    }

    /// The message of a recorded error, or nil when the reply says there is none.
    static func parseError(_ raw: String) -> String? {
        raw.hasPrefix("E:") ? String(raw.dropFirst(2)) : nil
    }

    // MARK: - evidence that the user's code started (#257 B2, #260)

    /// Run first inside a `--large` wrapper, before the user's code: the slot says the code started. A wrapper
    /// that does not parse never gets here, so a slot without this mark is a slot nothing ran for. It writes to
    /// the slot that is there and makes none, so a page that was replaced does not get a slot saying the code ran.
    var startedStatement: String {
        "if (window.\(key)) { window.\(key).started = true; }"
    }

    /// Run in the catch block of a `--large` wrapper: record what was thrown, whatever it is. The conversion can
    /// itself throw (`Symbol('x')` has no implicit string conversion, `Object.create(null)` has no `toString`), so it
    /// is guarded in two steps, and it declares nothing in the scope of the user's code. Same text as the plain
    /// path reports (`JavaScript error: null` for `throw null`).
    var recordErrorStatement: String {
        "if (window.\(key)) { window.\(key).err = (function(x){ try { return '' + (x && x.message !== undefined ? x.message : x); } catch(y) { try { return x.toString(); } catch(z) { return 'unprintable exception'; } } })(e); }"
    }

    /// How far a call got, from the slot alone.
    enum Progress: Equatable {
        /// No slot: the page was replaced since the slot was made (navigation, a same-address reload), or the read was lost.
        case gone
        /// The slot is there and the wrapper never started: nothing ran, and the other form may be tried.
        case notStarted
        /// The user's code started. `length` is the length of the result parked, nil if none was.
        case started(length: Int?)
    }

    var progressScript: String {
        "(function(){ var s = \(ref); return s ? (s.started ? 'started:' : 'idle:') + (s.len === undefined ? 'undefined' : '' + s.len) : 'gone'; })()"
    }

    /// Anything that is not one of the three answers reads as `gone`, which is the answer that never runs anything again.
    static func parseProgress(_ raw: String) -> Progress {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("started:") { return .started(length: parseLength(String(text.dropFirst("started:".count)))) }
        if text.hasPrefix("idle:") {
            // A length without a start cannot come from a wrapper; if it ever does, something ran.
            let length = parseLength(String(text.dropFirst("idle:".count)))
            return length == nil ? .notStarted : .started(length: length)
        }
        return .gone
    }

    var cleanupScript: String { "delete \(ref)" }

    /// How the error of a transfer that did not complete starts. One place, so the commands can tell it from
    /// a JavaScript error without matching text of their own.
    static let incompleteTransferPrefix = "JavaScript result transfer was incomplete"

    /// Whether `error` is a transfer that did not complete: the reply was cut or altered, or the slot was gone
    /// when it was read (the page was left, or another call replaced it).
    static func isIncompleteTransfer(_ error: Error) -> Bool {
        guard case .appleScriptFailed(let message)? = error as? SafariBrowserError else { return false }
        return message.hasPrefix(incompleteTransferPrefix)
    }

    /// Whether another round trip to remove the slot is worth it after `error`. After a timeout it is not.
    static func removalIsWorthTrying(after error: Error) -> Bool {
        switch error as? SafariBrowserError {
        case .timeout?, .processTimedOut?: return false
        default: return true
        }
    }

    /// One chunk: `<end>:<text><terminator>`.
    ///
    /// - `end` is where the chunk really ends. It stops one unit short rather than cut a surrogate pair in
    ///   two (each half would be dropped on the way back).
    /// - The terminator keeps the end of the text away from what is done to the end of an answer: the
    ///   runner removes a trailing newline, the daemon trims all trailing whitespace.
    /// - The read is refused (answers nothing) unless the slot still holds a text of `total` units, so a
    ///   slot that was replaced or removed since the length was read is an error, not a shorter result.
    func readScript(offset: Int, total: Int) -> String {
        """
        (function(){ var s = \(ref); if (!s || typeof s.text !== 'string' || s.text.length !== \(total)) return '';
        var t = s.text, a = \(offset), e = Math.min(a + \(Self.chunkSize), t.length);
        if (e < t.length) { var c = t.charCodeAt(e - 1), d = t.charCodeAt(e); if (c >= 55296 && c <= 56319 && d >= 56320 && d <= 57343) { e--; } }
        return e + ':' + t.substring(a, e) + '\\u001e'; })()
        """
    }

    // MARK: - what comes back

    /// A number as AppleScript prints it (`5489.0`) or as text (`5489`); nil for anything else,
    /// including `JSWrapper.lenUnsetSentinel`.
    static func parseLength(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value >= 0, value == value.rounded(), value < 1e15 else { return nil }
        return Int(value)
    }

    /// Read one chunk back. The reply must be exactly what `readScript` builds: `<end>:` then
    /// `end - offset` UTF-16 units of text, then the terminator. Anything else was cut or altered on the
    /// way back (or the slot was gone) and is an error; text that does not match its own length is never
    /// handed on as the result.
    ///
    /// Read by Unicode scalar, never by `Character`: a combining mark right after the `:` fuses with it
    /// into one `Character`, and the frame would look like it had no separator.
    static func parseFrame(_ raw: String, offset: Int, total: Int) throws -> (end: Int, text: String) {
        func incomplete(_ why: String) -> SafariBrowserError {
            .appleScriptFailed("\(incompleteTransferPrefix) at unit \(offset) of \(total): \(why). "
                + "The code ran and was not run again.")
        }
        let scalars = raw.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":") else { throw incomplete("no position in the reply") }
        let digits = scalars[..<colon]
        guard (1...15).contains(digits.count),
              digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let end = Int(String(digits)) else { throw incomplete("the position is not a number") }
        guard end > offset, end <= total else { throw incomplete("the position \(end) is outside \(offset + 1)...\(total)") }
        let body = scalars[scalars.index(after: colon)...]
        guard body.last == JSWrapper.inlineTerminator else { throw incomplete("the end marker is missing") }
        let text = String(String.UnicodeScalarView(body.dropLast()))
        guard text.utf16.count == end - offset else {
            throw incomplete("\(text.utf16.count) units arrived where \(end - offset) were announced")
        }
        return (end, text)
    }
}
