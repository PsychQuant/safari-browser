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
            let candidateCode = try staticCode(candidate)
            var infoRef: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(candidateCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
            let flags = ((infoRef as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32) ?? 0
            guard infoStatus == errSecSuccess, flags & SecCodeSignatureFlags.runtime.rawValue != 0 else {
                throw SelfUpdateError.candidateMissingRuntime
            }
            var requirement: SecRequirement?
            let reqStatus = SecCodeCopyDesignatedRequirement(try staticCode(installed), [], &requirement)
            guard reqStatus == errSecSuccess, let installedRequirement = requirement else {
                throw SelfUpdateError.candidateRequirement("could not read the installed requirement, status \(reqStatus)")
            }
            let satisfied = SecStaticCodeCheckValidity(
                candidateCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), installedRequirement)
            guard satisfied == errSecSuccess else {
                throw SelfUpdateError.candidateRequirement("status \(satisfied)")
            }
        })

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

enum SelfUpdateVersionProbeLive {
    /// Run `binary --version`; return stdout without one trailing newline.
    static func run(_ binary: URL, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw SelfUpdateError.versionProbe("\(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw SelfUpdateError.versionProbe("timed out after \(Int(timeout.rounded(.up))) s")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile().prefix(4096)
        guard process.terminationStatus == 0 else {
            throw SelfUpdateError.versionProbe("exit status \(process.terminationStatus)")
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

// MARK: - GitHub

struct GitHubReleaseSource: SelfUpdateReleaseSource {
    let userAgent: String

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SelfUpdateConstants.lookupTimeout
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    func latest() async throws -> SelfUpdateRelease {
        var request = URLRequest(url: SelfUpdateConstants.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw SelfUpdateError.lookup(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SelfUpdateError.lookup("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try SelfUpdateRelease.parse(data)
    }

    func download(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw SelfUpdateError.download(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SelfUpdateError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)")
        }
        guard data.count <= limit else {
            throw SelfUpdateError.assetTooLarge(name: url.lastPathComponent, size: data.count, limit: limit)
        }
        return data
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

    /// Stop each live daemon the way `daemon stop` does: send `daemon.shutdown`,
    /// then wait up to five seconds for it to go.
    static func stopper(environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfUpdateDaemonStopper {
        SelfUpdateDaemonStopper(stopAll: {
            guard case .ok(let directory) = DaemonPaths.resolveSocketDir(socketDir: nil, env: environment, allowUnsafe: false) else {
                return []
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
            return results
        })
    }
}
