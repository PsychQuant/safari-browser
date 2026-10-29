import Darwin
import Foundation
import Security

// MARK: - Signature (#314)

extension SelfUpdateSignatureVerifier {
    /// The trust anchor is the installed binary's designated requirement: a new
    /// release must be a Developer ID build with the hardened runtime that
    /// satisfies it. That requirement is also what TCC compares when deciding
    /// whether a Full Disk Access grant still applies.
    static let live = SelfUpdateSignatureVerifier(
        checkInstalled: { url in
            let verdict = SignatureAssessment.evaluate(at: url, requiredEntitlement: SelfUpdateConstants.requiredEntitlement)
            guard case .durable(shape: "Developer ID", _) = verdict else {
                throw SelfUpdateError.installedNotDeveloperID(describe(verdict))
            }
        },
        checkCandidate: { candidate, installed in
            let verdict = SignatureAssessment.evaluate(at: candidate, requiredEntitlement: SelfUpdateConstants.requiredEntitlement)
            guard case .durable(shape: "Developer ID", _) = verdict else {
                throw SelfUpdateError.candidateNotDeveloperID(describe(verdict))
            }
            try requireHardenedRuntime(candidate)
            try requireSatisfiesRequirement(of: installed, candidate: candidate)
        },
        checkRunningIsInstalled: { installed in
            try requireRunningCodeIs(installed)
        })

    /// Strict validation (what `codesign --verify --strict` adds) on every slice.
    static let candidateCheckFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)

    /// The candidate's signing flags include the hardened runtime.
    static func requireHardenedRuntime(_ candidate: URL) throws {
        var infoRef: CFDictionary?
        let status = SecCodeCopySigningInformation(try staticCode(candidate), SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let flags = ((infoRef as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        guard status == errSecSuccess, flags & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw SelfUpdateError.candidateMissingRuntime
        }
    }

    /// The candidate satisfies the **installed** binary's designated requirement —
    /// never its own, which every validly signed binary satisfies.
    static func requireSatisfiesRequirement(of installed: URL, candidate: URL) throws {
        var requirement: SecRequirement?
        let reqStatus = SecCodeCopyDesignatedRequirement(try staticCode(installed), [], &requirement)
        guard reqStatus == errSecSuccess, let installedRequirement = requirement else {
            throw SelfUpdateError.candidateRequirement("could not read the installed requirement, status \(reqStatus)")
        }
        let satisfied = SecStaticCodeCheckValidity(try staticCode(candidate), candidateCheckFlags, installedRequirement)
        guard satisfied == errSecSuccess else {
            throw SelfUpdateError.candidateRequirement("status \(satisfied)")
        }
    }

    /// This process's code hash equals the installed file's: the binary at the
    /// install path is still the one that is running.
    static func requireRunningCodeIs(_ installed: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              let mine = uniqueHash(runningStatic), let theirs = uniqueHash(try? staticCode(installed)),
              mine == theirs else {
            throw SelfUpdateError.installedChanged(installed.path)
        }
    }

    private static func uniqueHash(_ code: SecStaticCode?) -> Data? {
        guard let code else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &infoRef) == errSecSuccess else { return nil }
        return (infoRef as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw SelfUpdateError.candidateRequirement("could not read the code at \(url.lastPathComponent), status \(status)")
        }
        return code
    }

    static func describe(_ verdict: SignatureAssessment.Verdict) -> String {
        switch verdict {
        case .missingFile: return "missing"
        case .unavailable(let op, let status): return "could not \(op)\(status.map { ", status \($0)" } ?? "")"
        case .unsigned: return "unsigned"
        case .invalidSeal(let status): return "broken signature, status \(status)"
        case .adHoc: return "ad-hoc signed"
        case .missingEntitlement(let name, _): return "missing entitlement \(name)"
        case .unknownRequirement: return "an unrecognised designated requirement"
        case .unsatisfiedRequirement(_, let status): return "does not satisfy its own requirement, status \(status)"
        case .durable(let shape, _): return "\(shape) signed"
        }
    }
}

// MARK: - Version probe

/// Output collected while the probe runs, so a full pipe never blocks the child
/// and a grandchild that keeps the pipe open never blocks us.
private final class ProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private var overflowed = false
    let cap: Int
    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > cap { overflowed = true } else { data.append(chunk) }
    }
    func end() { lock.lock(); ended = true; lock.unlock() }
    var snapshot: (data: Data, ended: Bool, overflowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, ended, overflowed)
    }
}

enum SelfUpdateVersionProbeLive {
    static let outputCap = 4096
    /// After the probe exits, how long to wait for the pipe to close (a
    /// grandchild may hold it) before using what has arrived.
    static let drainGrace: TimeInterval = 0.5

    /// Run `binary --version` under one deadline that covers the run and reading
    /// its output; return stdout without one trailing newline.
    static func run(_ binary: URL, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let output = ProbeOutput(cap: outputCap)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { output.end(); handle.readabilityHandler = nil } else { output.append(chunk) }
        }
        // `waitUntilExit()` spins a run loop and can block for good on a
        // cooperative thread (seen in the tests); every wait here is a bounded poll.
        func stop() {
            reader.readabilityHandler = nil
            try? reader.close()
            if process.isRunning {
                process.terminate()
                kill(process.processIdentifier, SIGKILL)
                for _ in 0..<100 where process.isRunning { usleep(10_000) }
            }
        }
        do { try process.run() } catch {
            stop()
            throw SelfUpdateError.versionProbe(error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        while true {
            let now = Date()
            let state = output.snapshot
            if state.overflowed {
                stop()
                throw SelfUpdateError.versionProbe("printed more than \(outputCap) bytes")
            }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if state.ended || now.timeIntervalSince(exitedAt!) >= drainGrace { break }
            }
            if now >= deadline {
                stop()
                throw SelfUpdateError.versionProbe("timed out after \(Int(timeout.rounded(.up))) s")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        reader.readabilityHandler = nil
        try? reader.close()
        guard process.terminationStatus == 0 else {
            throw SelfUpdateError.versionProbe("exit status \(process.terminationStatus)")
        }
        var text = String(decoding: output.snapshot.data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

// MARK: - GitHub

struct GitHubReleaseSource: SelfUpdateReleaseSource {
    let userAgent: String
    /// Test seam: a `URLProtocol` stub in place of the network.
    var protocolClasses: [AnyClass]? = nil

    /// The lookup has one deadline for the whole request, not only for idle gaps.
    static func lookupConfiguration(protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SelfUpdateConstants.lookupTimeout
        configuration.timeoutIntervalForResource = SelfUpdateConstants.lookupTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    static func downloadConfiguration(protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SelfUpdateConstants.lookupTimeout
        configuration.timeoutIntervalForResource = SelfUpdateConstants.downloadTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    func latest() async throws -> SelfUpdateRelease {
        var request = URLRequest(url: SelfUpdateConstants.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: Self.lookupConfiguration(protocolClasses: protocolClasses))
        defer { session.finishTasksAndInvalidate() }
        let data = try await CappedDownload.fetch(request, userAgent: userAgent, session: session,
                                                  limit: SelfUpdateConstants.maxReleaseAnswerBytes,
                                                  name: "the release answer", failure: SelfUpdateError.lookup)
        return try SelfUpdateRelease.parse(data)
    }

    func download(_ url: URL, limit: Int) async throws -> Data {
        let session = URLSession(configuration: Self.downloadConfiguration(protocolClasses: protocolClasses))
        defer { session.finishTasksAndInvalidate() }
        return try await CappedDownload.fetch(URLRequest(url: url), userAgent: userAgent, session: session,
                                              limit: limit, name: url.lastPathComponent, failure: SelfUpdateError.download)
    }
}

/// Receives a response chunk by chunk and cancels it as soon as more than
/// `limit` bytes have arrived (or the declared length is over the limit).
private final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let name: String
    private let failure: (String) -> SelfUpdateError
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?

    private init(limit: Int, name: String, failure: @escaping (String) -> SelfUpdateError) {
        self.limit = limit; self.name = name; self.failure = failure
    }

    static func fetch(_ request: URLRequest, userAgent: String, session: URLSession, limit: Int, name: String,
                      failure: @escaping (String) -> SelfUpdateError) async throws -> Data {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = CappedDownload(limit: limit, name: name, failure: failure)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    private func attach(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        if let result { continuation.resume(with: result) } else { self.continuation = continuation }
    }

    private func finish(_ outcome: Result<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        result = outcome
        continuation?.resume(with: outcome)
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(failure("HTTP \(status) for \(name)")))
            return completionHandler(.cancel)
        }
        if response.expectedContentLength > Int64(limit) {
            finish(.failure(SelfUpdateError.assetTooLarge(name: name, size: Int(response.expectedContentLength), limit: limit)))
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        data.append(chunk)
        let size = data.count
        lock.unlock()
        if size > limit {
            finish(.failure(SelfUpdateError.assetTooLarge(name: name, size: size, limit: limit)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(failure(error.localizedDescription)))
        } else {
            lock.lock(); let body = data; lock.unlock()
            finish(.success(body))
        }
    }
}

// MARK: - Daemons

enum SelfUpdateDaemonsLive {
    /// Every `safari-browser-<name>.sock` in `directory` whose daemon is alive.
    static func liveNames(in directory: String) -> [String] {
        let prefix = DaemonClient.socketPrefix, suffix = DaemonClient.socketSuffix
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries.compactMap { entry -> String? in
            guard entry.hasPrefix(prefix), entry.hasSuffix(suffix), entry.count > prefix.count + suffix.count else { return nil }
            let name = String(entry.dropFirst(prefix.count).dropLast(suffix.count))
            let alive = DaemonServeLoop.isDaemonAlive(
                socketPath: DaemonClient.socketPath(dir: directory, name: name),
                pidPath: DaemonClient.pidPath(dir: directory, name: name))
            return alive ? name : nil
        }.sorted()
    }

    /// Stop each live daemon in the default socket directory the way `daemon stop`
    /// does: send `daemon.shutdown`, then wait up to five seconds for it to go.
    /// The report says which directory was looked in — daemons elsewhere
    /// (`--socket-dir`, another `TMPDIR`) are not found and keep running.
    static func stopper(environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfUpdateDaemonStopper {
        SelfUpdateDaemonStopper(stopAll: {
            guard case .ok(let directory) = DaemonPaths.resolveSocketDir(socketDir: nil, env: environment, allowUnsafe: false) else {
                return SelfUpdateDaemonReport(directory: nil, results: [])
            }
            var results: [SelfUpdateDaemonResult] = []
            for name in liveNames(in: directory) {
                _ = try? await DaemonClient.sendRequest(name: name, method: "daemon.shutdown", params: Data("{}".utf8),
                                                        requestId: 1, timeout: 2.0, socketDir: directory)
                let socket = DaemonClient.socketPath(dir: directory, name: name)
                let pid = DaemonClient.pidPath(dir: directory, name: name)
                let deadline = Date().addingTimeInterval(5)
                var stopped = false
                while Date() < deadline {
                    if !DaemonServeLoop.isDaemonAlive(socketPath: socket, pidPath: pid) { stopped = true; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                results.append(SelfUpdateDaemonResult(name: name, stopped: stopped))
            }
            return SelfUpdateDaemonReport(directory: directory, results: results)
        })
    }
}
