import ArgumentParser
import Foundation

/// `safari-browser self-update [--check [--json]]` (#314).
///
/// Interference: Non-interfering. It never drives Safari or the UI. It requests
/// the GitHub API and the release download URLs (GitHub chooses where downloads
/// redirect; the bytes are held to the checksum and the designated requirement).
/// In the install directory it writes its binary, `<binary>.previous`, a lock
/// file, and transient `.safari-browser.self-update*` files. The trust anchor is
/// the installed binary's designated requirement — see
/// `SelfUpdateSignatureVerifier.live`.
struct SelfUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Replace this binary with the latest verified GitHub release (--check only reports)",
        discussion: """
            Downloads the latest release of PsychQuant/safari-browser, checks its
            sha256, requires a Developer ID signature with the hardened runtime that
            satisfies this binary's designated requirement, checks that it reports the
            release tag, then replaces this binary atomically and keeps the old one as
            <binary>.previous. One run at a time per install directory. Afterwards it
            stops every daemon in the default socket directory; one started with
            --socket-dir elsewhere or from another TMPDIR keeps running the old binary
            until you stop it, and a running `safari-browser mcp` server needs a restart.
            It does not ask before replacing; use --check to see what it would do.
            """
    )

    @Flag(name: .long, help: "Only report whether a newer release exists; download and write nothing.")
    var check = false

    @Flag(name: .long, help: "With --check, print one JSON object (status: up-to-date, update-available, ahead, not-comparable, lookup-failed).")
    var json = false

    func validate() throws {
        if json && !check { throw ValidationError("--json is only valid together with --check") }
    }

    func run() async throws {
        let updater = SelfUpdater(
            installedVersion: BuildVersion.value,
            // Resolved without failing here: `--check` never needs it, and
            // `update()` reports an unresolvable path as its own error.
            executable: Self.runningExecutable(),
            source: GitHubReleaseSource(userAgent: "safari-browser/\(BuildVersion.value)"),
            verifier: .live,
            probe: { try await SelfUpdateVersionProbeLive.run($0, timeout: SelfUpdateConstants.probeTimeout) },
            daemons: SelfUpdateDaemonsLive.stopper())
        let out: @Sendable (String) -> Void = { print($0) }
        let err: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        let code = check
            ? await SelfUpdateRunner.check(updater, json: json, out: out, err: err)
            : await SelfUpdateRunner.update(updater, out: out, err: err)
        if code != 0 { throw ExitCode(code) }
    }

    /// The path the kernel started this process from, as given (no lexical `..`
    /// folding before `realpath`); `argv[0]` if that cannot be read.
    static func runningExecutable() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0, size < 1024 * 1024 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return URL(fileURLWithPath: CommandLine.arguments.first ?? "safari-browser")
    }
}

/// Turns `SelfUpdater` results into output lines and exit codes. Kept apart
/// from the command so tests can run it with fakes and captured output.
enum SelfUpdateRunner {
    static func check(_ updater: SelfUpdater, json: Bool,
                      out: (String) -> Void, err: (String) -> Void) async -> Int32 {
        let result = await updater.check()
        if json {
            out(renderJSON(result))
        } else if let line = humanLine(result) {
            out(line)
        } else {
            err("self-update: \(result.error ?? "release lookup failed")")
        }
        return result.status == .lookupFailed ? 1 : 0
    }

    static func update(_ updater: SelfUpdater, out: (String) -> Void, err: (String) -> Void) async -> Int32 {
        do {
            switch try await updater.update() {
            case .upToDate(let tag):
                out("safari-browser \(tag) is up to date; nothing to do")
            case .ahead(let installed, let latest):
                out("installed \(installed) is newer than the latest release \(latest); not replacing it")
            case .replaced(let from, let to, let target, let report):
                let shown = SelfUpdater.oneLine(target)
                out("updated safari-browser \(from) → \(to) at \(shown) (previous kept as \(shown).previous)")
                // A daemon left running still runs the old binary. Before #304 the
                // handshake could not tell builds apart, so it also kept answering
                // this CLI; say what is true either way.
                let stale = "keeps running the old binary"
                let daemons = report.results
                for daemon in daemons where daemon.stopped { out("daemon \(SelfUpdater.oneLine(daemon.name)): stopped") }
                for daemon in daemons where !daemon.stopped {
                    err("warning: daemon \(SelfUpdater.oneLine(daemon.name)) did not stop within 5 s and \(stale) — stop it with: safari-browser daemon stop\(nameFlag(daemon.name))")
                }
                for daemon in daemons where daemon.stopped {
                    out("restart it with: safari-browser daemon start\(nameFlag(daemon.name))")
                }
                if let directory = report.directory {
                    out("note: daemons were looked for in \(SelfUpdater.oneLine(directory)) only; one started with --socket-dir elsewhere or from another TMPDIR \(stale) until you stop it")
                } else {
                    err("warning: the daemon socket directory could not be resolved, so no daemon was stopped; a running daemon \(stale) — stop it with: safari-browser daemon stop")
                }
                out("note: a running `safari-browser mcp` server refuses tool calls until it is restarted")
            }
            return 0
        } catch {
            err("self-update: \(SelfUpdater.oneLine("\(error)"))")
            return 1
        }
    }

    private static func nameFlag(_ name: String) -> String {
        name == DaemonClient.defaultName ? "" : " --name \(shellWord(name))"
    }

    /// `word` as one shell word: bare when it is plainly safe, otherwise single-
    /// quoted, with line breaks flattened first so a printed command stays one line.
    static func shellWord(_ word: String) -> String {
        let flat = SelfUpdater.oneLine(word)
        let safe = !flat.isEmpty && flat.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0))
        }
        return safe ? flat : "'" + flat.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func humanLine(_ r: SelfUpdateCheckResult) -> String? {
        let latest = r.latest ?? "?"
        switch r.status {
        case .upToDate: return "safari-browser \(latest) is up to date"
        case .updateAvailable: return "safari-browser \(latest) is available (installed \(r.installed)) — run: safari-browser self-update"
        case .ahead: return "installed \(r.installed) is newer than the latest release \(latest)"
        case .notComparable: return "installed version '\(r.installed)' cannot be compared with the latest release \(latest)"
        case .lookupFailed: return nil
        }
    }

    /// `{"installed":…,"latest":…,"status":…}` in that order, plus `error` when
    /// the lookup failed. Values are JSON-escaped one by one.
    static func renderJSON(_ r: SelfUpdateCheckResult) -> String {
        func quote(_ s: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        var fields = [
            "\"installed\":\(quote(r.installed))",
            "\"latest\":\(r.latest.map(quote) ?? "null")",
            "\"status\":\(quote(r.status.rawValue))",
        ]
        if let error = r.error { fields.append("\"error\":\(quote(error))") }
        return "{" + fields.joined(separator: ",") + "}"
    }
}
