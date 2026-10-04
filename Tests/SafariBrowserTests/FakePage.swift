import Foundation
import JavaScriptCore
@testable import SafariBrowser

/// A page the CLI's `do JavaScript` really runs in (#190).
///
/// The fake-Safari tests answer scripts from a table: they can say "the CLI sent N calls", but never
/// "the result of call A is not what call B left in the page", because nothing ever ran. This one
/// takes the JavaScript out of the AppleScript the CLI sends and evaluates it in JavaScriptCore, in
/// one global object shared by every call, so state left behind by one call is exactly what the next
/// call sees, as in a real tab.
///
/// What it models, because each was measured on a real Safari (#255):
/// - a script that does not parse or throws answers nothing (`do JavaScript` swallows the error);
/// - a number answers as AppleScript prints it (`5` -> `5.0`), `undefined` as `missing value`;
/// - `osascript` appends a newline and the runner removes a trailing one (two when the answer
///   itself ends in one), or the daemon trims all trailing whitespace (`Transport`);
/// A lone surrogate cannot be modelled here (a Swift `String` cannot hold one); tests that need it
/// check `isWellFormed()` inside the page instead.
final class FakePage: @unchecked Sendable {
    enum Transport {
        /// `osascript`: the runner's `\n$` removal.
        case stateless
        /// The daemon: trims all whitespace at both ends.
        case daemon
    }

    private let lock = NSLock()
    private let context: JSContext
    private(set) var sent: [String] = []
    var transport: Transport = .stateless
    /// What `URL of <tab>` answered before the code ran (the capturing scripts of #255 return it first).
    var url = "https://w1.example/53"
    /// A plain `do JavaScript` answer longer than this comes back empty, as an over-long one did on the
    /// Safari that made #1 add the chunked read.
    var maxAnswerUnits: Int?
    /// Answers a script instead of running it; return nil to let the page run it.
    var forced: ((String) -> String?)?
    /// Called with the script (AppleScript text) before it runs; a test can use it to run another
    /// call in between, which is how an interleaving is made deterministic.
    var beforeRun: ((String) -> Void)?

    init() {
        context = JSContext()!
        context.exceptionHandler = { _, _ in }
        context.evaluateScript("var window = this;")
    }

    /// Give the page a `document` with this text, enough for `document.body.innerText`.
    func setDocument(innerText: String) {
        let data = try! JSONSerialization.data(withJSONObject: [innerText], options: [])
        let array = String(decoding: data, as: UTF8.self)
        _ = evaluate("var document = { body: { innerText: \(array)[0] } };")
    }

    /// Run `body` against the page's global object, e.g. to read what a call left behind.
    func evaluate(_ source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = context.evaluateScript(source)
        return value.flatMap { $0.isUndefined ? nil : $0.toString() }
    }

    func has(_ key: String) -> Bool { evaluate("typeof window.\(key) !== 'undefined'") == "true" }

    /// Property names on the page that start with `prefix`.
    func keys(withPrefix prefix: String) -> [String] {
        (evaluate("Object.getOwnPropertyNames(window).filter(function(k){return k.indexOf('\(prefix)')===0}).join(',')") ?? "")
            .split(separator: ",").map(String.init)
    }

    /// Every own property name of the page's global object.
    func windowKeys() -> Set<String> {
        Set((evaluate("Object.getOwnPropertyNames(window).join('\\n')") ?? "").split(separator: "\n").map(String.init))
    }

    var javaScripts: [String] { lock.withLock { sent }.compactMap(Self.javaScript(in:)) }

    /// The runner to install with `DaemonRequestContext.$appleScriptRunner`.
    func respond(_ appleScript: String) throws -> String {
        beforeRun?(appleScript)
        lock.lock(); sent.append(appleScript); lock.unlock()
        guard let js = Self.javaScript(in: appleScript) else {
            // not a `do JavaScript` script (a target read, an anchor): nothing the page can answer
            return ""
        }
        var answer = forced?(js) ?? lock.withLock { run(js) }
        if let limit = maxAnswerUnits, answer.utf16.count > limit { answer = "" }
        let reply: String
        if appleScript.contains("return _u & (character id 29) & _r") {
            reply = url + "\u{1D}" + answer
        } else {
            reply = answer
        }
        return carry(reply)
    }

    private func run(_ js: String) -> String {
        var threw = false
        context.exceptionHandler = { _, _ in threw = true }
        let value = context.evaluateScript(js)
        context.exceptionHandler = { _, _ in }
        if threw { return "" }
        guard let value else { return "" }
        if value.isUndefined || value.isNull { return "missing value" }
        if value.isBoolean { return value.toBool() ? "true" : "false" }
        if value.isNumber {
            let number = value.toDouble()
            return number == number.rounded() && abs(number) < 1e15 ? String(format: "%.1f", number) : "\(number)"
        }
        return value.toString() ?? ""
    }

    /// What osascript and the runner do to an answer on its way back.
    private func carry(_ answer: String) -> String {
        switch transport {
        case .stateless:
            return (answer + "\n").replacingOccurrences(of: "\\n$", with: "", options: .regularExpression)
        case .daemon:
            return answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The JavaScript of the statement `do JavaScript "<escaped>" in <ref>`.
    static func javaScript(in appleScript: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"do JavaScript "((?:[^"\\]|\\.)*)" in "#),
              let match = regex.firstMatch(in: appleScript, range: NSRange(appleScript.startIndex..., in: appleScript)),
              let range = Range(match.range(at: 1), in: appleScript) else { return nil }
        var out = ""
        var escaped = false
        for ch in appleScript[range] {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
