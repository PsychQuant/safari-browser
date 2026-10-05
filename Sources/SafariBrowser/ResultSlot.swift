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
    /// error the code recorded and to read from the slot how far the call got (`progressScript`).
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

    // MARK: - bounded retention (#193)

    /// How long a slot may go unused before a later call that makes a slot removes it, in milliseconds of the
    /// page's own clock. A call touches its slot at every round trip (well under a second apart), so only a slot
    /// nobody is using, or one whose call stalled for this long, is ever removed.
    static let retentionMilliseconds = 600_000

    /// The page's clock as a number, or `undefined` when it cannot be read: `Date.now` may be replaced by a
    /// page (fake timers, a privacy extension), may throw, and may answer something that is not a number.
    /// `n === n` is false only for `NaN`. No global other than `Date` is used (page code can reassign them, #76).
    private static let nowExpression =
        "(function(){ try { var n = Date.now(); return typeof n === 'number' && n === n ? n : undefined; } catch (x) { return undefined; } })()"

    /// The time stamp of a new slot: the clock, or nothing when it cannot be read (such a slot is never removed).
    static let stampExpression = nowExpression

    /// Record a use of the slot `s`, which must be in scope. A clock that cannot be read leaves the stamp as it was.
    private static let touchStatement =
        "try { var q = \(nowExpression); if (q !== undefined) { s.u = q; } } catch (x) {}"

    /// Remove every property of `window` that is an abandoned slot: its name starts with `__sbr_`, its value is an
    /// object, and its stamp `u` is a number older than `retentionMilliseconds`. A slot without a stamp (made by a
    /// CLI that did not stamp), a stamp that is not a number, and any other property are left alone, and so is
    /// everything when the clock cannot be read. The whole walk is in a `try`: a page that makes it fail loses
    /// nothing but the removal. It declares nothing in the scope of the user's code (it is a function of its own).
    static let sweepExpression = """
        (function(){ try { var q = \(nowExpression); if (q === undefined) { return; } var names = Object.keys(window); \
        for (var i = 0; i < names.length; i++) { if (names[i].indexOf('\(keyPrefix)') === 0) { var v = window[names[i]]; \
        if (v && typeof v === 'object' && typeof v.u === 'number' && v.u < q - \(retentionMilliseconds)) { delete window[names[i]]; } } } } catch (x) {} })()
        """

    // MARK: - scripts

    /// Marks the slot as "nothing stored yet and nothing started": `progressScript` reports it as `idle:undefined`, and a
    /// page that was replaced has no slot at all, which it reports as `gone`. `lengthScript` reports both as
    /// `JSWrapper.lenUnsetSentinel`.
    var presetScript: String { "(\(Self.sweepExpression), \(ref) = { u: \(Self.stampExpression) })" }

    /// Evaluate `expression`, make it text, replace a lone surrogate with U+FFFD, and park it.
    ///
    /// The slot object is made BEFORE the expression is evaluated, so the wrapper can mark it and record an error
    /// even in a page that was replaced after the preset, and an expression that does not parse leaves no slot or an
    /// untouched preset. `toWellFormed()` because osascript drops a lone
    /// surrogate without a word (#255); U+FFFD has the same length and survives. A Safari without
    /// `toWellFormed` keeps the lone surrogate and the chunk read reports the length mismatch.
    ///
    /// The user's expression is an ARGUMENT of the function that stores it, so it is evaluated where
    /// `do JavaScript` runs it, not inside a function that declares variables of its own: a `var s` or
    /// `var r` there would shadow a page global named `s` or `r` and the expression would read
    /// `undefined` without a word.
    func storeScript(_ expression: String) -> String {
        """
        (\(Self.sweepExpression), \(ref) = \(ref) || { u: \(Self.stampExpression) }, (function(r){ if (typeof r.toWellFormed === 'function') { r = r.toWellFormed(); } var s = \(ref); s.text = r; s.len = r.length; \(Self.touchStatement) })('' + (
        \(expression)
        )))
        """
    }

    /// The length as text, or `JSWrapper.lenUnsetSentinel` when the slot is missing or nothing was stored.
    var lengthScript: String {
        "(function(){ var s = \(ref); if (s) { \(Self.touchStatement) } return s ? '' + s.len : 'undefined'; })()"
    }

    /// The error a `--large` wrapper recorded, as `E:<text>` (the text may be empty), or
    /// `JSWrapper.lenUnsetSentinel` when nothing was recorded. The prefix is what tells an error whose message is
    /// empty (`throw ''`) from no error.
    var errorScript: String {
        "(function(){ var s = \(ref); if (s) { \(Self.touchStatement) } return s && s.err !== undefined ? 'E:' + s.err : 'undefined'; })()"
    }

    /// The message of a recorded error, or nil when the reply says there is none. The prefix is read by Unicode
    /// SCALAR: a message that starts with a combining mark, a variation selector or a joiner fuses with the `:` into one
    /// `Character`, and a Character-based `hasPrefix("E:")` would read that error as no error (#255).
    static func parseError(_ raw: String) -> String? {
        let prefix = "E:".unicodeScalars
        guard raw.unicodeScalars.starts(with: prefix) else { return nil }
        return String(String.UnicodeScalarView(raw.unicodeScalars.dropFirst(prefix.count)))
    }

    // MARK: - evidence that the user's code started (#257 B2, #260)

    /// Run first inside a `--large` wrapper, before the user's code: the slot says the code started. A wrapper
    /// that does not parse never gets here, so a slot without this mark is a slot nothing ran for. It writes to the
    /// slot that is there and makes none. (`storeScript` makes the slot before it evaluates the wrapper, so in practice
    /// the slot is always there; the guard keeps a wrapper that is evaluated on its own from inventing one.)
    var startedStatement: String {
        "if (window.\(key)) { window.\(key).started = true; }"
    }

    /// Run in the catch block of a `--large` wrapper: say that the code threw, then record what was thrown, whatever it
    /// is. The flag comes first and cannot fail, so an error whose text cannot be recorded or read back is still an error
    /// and never reads as a result that is empty. The conversion can itself throw (`Symbol('x')` has no implicit string
    /// conversion, `Object.create(null)` has no `toString`, a getter can throw), so it is guarded in three steps and
    /// always yields a string; it declares nothing in the scope of the user's code (the helper functions have their own).
    /// The text is cut at 16384 units so it can be read back in one answer: a longer plain answer comes back empty.
    /// Same text as the plain path reports (`JavaScript error: null` for `throw null`).
    var recordErrorStatement: String {
        "if (window.\(key)) { window.\(key).threw = true; window.\(key).err = (function(m){ m = m.length > 16384 ? m.slice(0, 16384) + '\u{2026}' : m; return typeof m.toWellFormed === 'function' ? m.toWellFormed() : m; })((function(x){ try { return '' + (x && x.message !== undefined ? x.message : x); } catch(y) { try { return '' + x.toString(); } catch(z) { return 'unprintable exception'; } } })(e)); }"
    }

    /// How far a call got, from the slot alone.
    enum Progress: Equatable {
        /// No slot: the page was replaced since the slot was made (navigation, a same-address reload), or the read was lost.
        case gone
        /// The slot is there and the wrapper never started: nothing ran, and the other form may be tried.
        case notStarted
        /// The user's code started. `length` is the length of the result parked, nil if none was.
        case started(length: Int?)
        /// The user's code started and threw (whether or not what it threw could be read back).
        case threw
    }

    var progressScript: String {
        "(function(){ var s = \(ref); if (s) { \(Self.touchStatement) } return s ? (s.threw ? 'threw:' : s.started ? 'started:' : 'idle:') + (s.len === undefined ? 'undefined' : '' + s.len) : 'gone'; })()"
    }

    /// Anything that is not one of the four answers reads as `gone`, which is the answer that never runs anything again.
    /// What follows the colon has to be `undefined` or a length; a tail that is neither is a damaged answer. Only the
    /// exact `idle:undefined` lets the other form run.
    static func parseProgress(_ raw: String) -> Progress {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func tail(of prefix: String) -> (length: Int?, ok: Bool)? {
            guard text.hasPrefix(prefix) else { return nil }
            let rest = String(text.dropFirst(prefix.count))
            if rest == JSWrapper.lenUnsetSentinel { return (nil, true) }
            if let length = parseLength(rest) { return (length, true) }
            return (nil, false)
        }
        if let t = tail(of: "threw:") { return t.ok ? .threw : .gone }
        if let t = tail(of: "started:") { return t.ok ? .started(length: t.length) : .gone }
        if let t = tail(of: "idle:") {
            // A length without a start cannot come from a wrapper; if it ever does, something ran.
            if !t.ok { return .gone }
            return t.length == nil ? .notStarted : .started(length: t.length)
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
        \(Self.touchStatement)
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
