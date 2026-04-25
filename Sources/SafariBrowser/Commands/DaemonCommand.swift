import ArgumentParser
import Foundation
import Darwin

/// Subcommand group that manages the opt-in persistent daemon.
///
/// Wired in task 6.2 to use `DaemonServeLoop` + `DaemonClient` for the
/// actual lifecycle. Full contract lives in
/// `openspec/specs/persistent-daemon/spec.md`.
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the opt-in Safari-browser daemon (start / stop / status / logs)",
        subcommands: [
            DaemonStartCommand.self,
            DaemonStopCommand.self,
            DaemonStatusCommand.self,
            DaemonLogsCommand.self,
            DaemonServeCommand.self,
        ]
    )
}

/// Resolve the daemon namespace from flag, env, or default.
struct DaemonNameFlag: ParsableArguments {
    @Option(name: .long, help: "Daemon namespace. Precedence: flag > SAFARI_BROWSER_NAME env > 'default'.")
    var name: String?
}

/// Section 1 follow-up of `daemon-security-hardening`: explicit override
/// for the directory that holds socket / pid / log files, plus an opt-in
/// to bypass the world-writable parent directory check. The pure
/// resolver `DaemonPaths.resolveSocketDir` enforces the safety contract;
/// these flags expose it on the CLI surface.
struct DaemonSocketDirFlags: ParsableArguments {
    @Option(
        name: .long,
        help: "Override the directory holding the daemon's socket / pid / log files. Defaults to $TMPDIR (refuses to start when TMPDIR is unset)."
    )
    var socketDir: String?

    @Flag(
        name: .long,
        help: "Allow the daemon to bind in a world-writable directory. NOT RECOMMENDED — exists to unblock CI runners or constrained environments where the parent dir cannot be tightened."
    )
    var allowUnsafeSocketDir: Bool = false
}

/// Resolve the directory the daemon should use, applying the security
/// rules (TMPDIR rejection, world-writable parent rejection unless
/// `allowUnsafe`). Called by every daemon subcommand before composing
/// concrete socket / pid / log paths.
func resolveDaemonSocketDir(flags: DaemonSocketDirFlags) throws -> String {
    let result = DaemonPaths.resolveSocketDir(
        socketDir: flags.socketDir,
        env: ProcessInfo.processInfo.environment,
        allowUnsafe: flags.allowUnsafeSocketDir
    )
    switch result {
    case .ok(let dir):
        return dir
    case .rejected(_, let message):
        throw ValidationError(message)
    }
}

// MARK: - daemon start

struct DaemonStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the daemon (idempotent: no-op if already running)"
    )

    @OptionGroup var nameFlag: DaemonNameFlag
    @OptionGroup var socketDirFlags: DaemonSocketDirFlags

    var name: String? { nameFlag.name }

    func run() async throws {
        let resolvedName = DaemonClient.resolveName(flag: nameFlag.name)
        let dir = try resolveDaemonSocketDir(flags: socketDirFlags)
        let socketPath = DaemonClient.socketPath(dir: dir, name: resolvedName)
        let pidPath = DaemonClient.pidPath(dir: dir, name: resolvedName)
        let logPath = DaemonClient.logPath(dir: dir, name: resolvedName)

        if DaemonServeLoop.isDaemonAlive(socketPath: socketPath, pidPath: pidPath) {
            print("daemon \(resolvedName): already running")
            return
        }

        // Clean up stale artefacts from a crashed prior run.
        unlink(socketPath)
        unlink(pidPath)

        // Spawn a detached child running `safari-browser daemon __serve`.
        // Redirect its stdout/stderr to the log file so tailing `logs`
        // shows whatever the daemon printed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: currentExecutablePath())
        var serveArgs = ["daemon", "__serve", "--name", resolvedName]
        if let explicit = socketDirFlags.socketDir, !explicit.isEmpty {
            serveArgs.append(contentsOf: ["--socket-dir", explicit])
        }
        if socketDirFlags.allowUnsafeSocketDir {
            serveArgs.append("--allow-unsafe-socket-dir")
        }
        process.arguments = serveArgs
        process.standardInput = nil
        let logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if logFd >= 0 {
            let logHandle = FileHandle(fileDescriptor: logFd, closeOnDealloc: true)
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw ValidationError("failed to spawn daemon: \(error)")
        }

        // Poll for socket readiness up to 5 seconds. If the child dies
        // before binding (bind error, permission, etc.) we'll time out and
        // surface a non-zero exit.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                print("daemon \(resolvedName): started (pid \(process.processIdentifier))")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ValidationError("daemon did not bind socket within 5 seconds; check \(logPath)")
    }
}

// MARK: - daemon stop

struct DaemonStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the daemon gracefully (idempotent: no-op if not running)"
    )

    @OptionGroup var nameFlag: DaemonNameFlag
    @OptionGroup var socketDirFlags: DaemonSocketDirFlags

    var name: String? { nameFlag.name }

    func run() async throws {
        let resolvedName = DaemonClient.resolveName(flag: nameFlag.name)
        let dir = try resolveDaemonSocketDir(flags: socketDirFlags)
        let socketPath = DaemonClient.socketPath(dir: dir, name: resolvedName)
        let pidPath = DaemonClient.pidPath(dir: dir, name: resolvedName)

        if !DaemonServeLoop.isDaemonAlive(socketPath: socketPath, pidPath: pidPath) {
            return
        }

        // Fire-and-forget the shutdown request; the daemon returns the
        // response BEFORE tearing down its own socket. Any error here
        // (including remoteError from a handler bug) is swallowed because
        // `stop` is defined as idempotent.
        _ = try? await DaemonClient.sendRequest(
            name: resolvedName,
            method: "daemon.shutdown",
            params: Data("{}".utf8),
            requestId: 1,
            timeout: 2.0,
            socketDir: socketDirFlags.socketDir
        )

        // Poll for the pid file to disappear. Bound to 5 seconds matching
        // the Non-Interference "terminate within 5s" scenario.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !DaemonServeLoop.isDaemonAlive(socketPath: socketPath, pidPath: pidPath) {
                print("daemon \(resolvedName): stopped")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("daemon did not exit within 5 seconds")
    }
}

// MARK: - daemon status

struct DaemonStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print daemon pid / uptime / request count / pre-compiled script count / last activity"
    )

    @OptionGroup var nameFlag: DaemonNameFlag
    @OptionGroup var socketDirFlags: DaemonSocketDirFlags

    var name: String? { nameFlag.name }

    func run() async throws {
        let resolvedName = DaemonClient.resolveName(flag: nameFlag.name)
        let dir = try resolveDaemonSocketDir(flags: socketDirFlags)
        let socketPath = DaemonClient.socketPath(dir: dir, name: resolvedName)
        let pidPath = DaemonClient.pidPath(dir: dir, name: resolvedName)

        if !DaemonServeLoop.isDaemonAlive(socketPath: socketPath, pidPath: pidPath) {
            print("daemon \(resolvedName): not running")
            return
        }

        let resultData = try await DaemonClient.sendRequest(
            name: resolvedName,
            method: "daemon.status",
            params: Data("{}".utf8),
            requestId: 1,
            timeout: 2.0,
            socketDir: socketDirFlags.socketDir
        )
        let obj = (try? JSONSerialization.jsonObject(with: resultData, options: [])) as? [String: Any] ?? [:]
        let pid = (obj["pid"] as? Int) ?? -1
        let uptime = (obj["uptimeSeconds"] as? Double) ?? 0
        let requestCount = (obj["requestCount"] as? Int) ?? 0
        let preCompiledCount = (obj["preCompiledCount"] as? Int) ?? 0
        print("daemon \(resolvedName):")
        print("  pid:                \(pid)")
        print("  uptime:             \(Int(uptime))s")
        print("  requests served:    \(requestCount)")
        print("  pre-compiled scripts: \(preCompiledCount)")
    }
}

// MARK: - daemon logs

struct DaemonLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the daemon log file contents"
    )

    @OptionGroup var nameFlag: DaemonNameFlag
    @OptionGroup var socketDirFlags: DaemonSocketDirFlags

    var name: String? { nameFlag.name }

    func run() async throws {
        let resolvedName = DaemonClient.resolveName(flag: nameFlag.name)
        let dir = try resolveDaemonSocketDir(flags: socketDirFlags)
        let logPath = DaemonClient.logPath(dir: dir, name: resolvedName)
        guard FileManager.default.fileExists(atPath: logPath) else {
            print("daemon \(resolvedName): no log file at \(logPath)")
            return
        }
        if let contents = try? String(contentsOfFile: logPath, encoding: .utf8) {
            print(contents, terminator: "")
        }
    }
}

// MARK: - executable path helper

/// Return the absolute path of the currently-running binary via
/// `_NSGetExecutablePath`. Used by `daemon start` to spawn itself as the
/// serve child. `CommandLine.arguments[0]` is unreliable because it
/// carries whatever form the shell resolved, and `URL(fileURLWithPath:)`
/// reinterprets relative paths against the process cwd rather than PATH.
private func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _ = _NSGetExecutablePath(&buf, &size)
    return String(cString: buf)
}

// MARK: - daemon __serve (hidden, hosts the actual daemon process)

struct DaemonServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__serve",
        abstract: "[internal] Run as the daemon process; not invoked directly",
        shouldDisplay: false
    )

    @OptionGroup var nameFlag: DaemonNameFlag
    @OptionGroup var socketDirFlags: DaemonSocketDirFlags

    func run() async throws {
        // Detach from the parent's terminal so closing the shell does not
        // send SIGHUP to the daemon. `setsid` moves us into a new session
        // and process group; we also ignore SIGHUP belt-and-braces.
        signal(SIGHUP, SIG_IGN)
        _ = setsid()

        let resolvedName = DaemonClient.resolveName(flag: nameFlag.name)
        let dir = try resolveDaemonSocketDir(flags: socketDirFlags)
        let socketPath = DaemonClient.socketPath(dir: dir, name: resolvedName)
        let pidPath = DaemonClient.pidPath(dir: dir, name: resolvedName)
        let logPath = DaemonClient.logPath(dir: dir, name: resolvedName)
        let idleTimeout = DaemonServer.Instance.resolveIdleTimeout(
            env: ProcessInfo.processInfo.environment
        )

        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: idleTimeout,
            logPath: logPath
        )

        // Block until either the idle watchdog or an explicit
        // `daemon.shutdown` method triggers `stop()`. Both paths resume
        // the continuation in `waitUntilStopped`.
        await loop.waitUntilStopped()
    }
}
