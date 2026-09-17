import AppKit
import ArgumentParser
import Darwin
import Foundation

/// A fixed transaction descriptor. No script source crosses the worker boundary.
struct NativeUploadRequest: Codable, Sendable, Equatable {
    var version: Int = 1
    var selector: String
    var path: String
    var fileSize: Int64
    var modificationTimeMilliseconds: Int64
    var clipboardChangeCount: Int
    var window: Int?
    var timeout: Double
    var nonce: String
    var windowID: Int
    var tabIndex: Int?
    var deadlineUptime: Double

    static let maximumBytes = 128 * 1024

    func encodedArgument() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else {
            throw ValidationError("Native upload request exceeds its size limit")
        }
        return data.base64EncodedString()
    }

    static func decode(_ encoded: String) throws -> Self {
        guard encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), data.count <= maximumBytes else {
            throw ValidationError("Invalid native upload request encoding or size")
        }
        let allowed: Set<String> = ["version", "selector", "path", "fileSize", "modificationTimeMilliseconds",
                                   "clipboardChangeCount", "window", "timeout", "nonce", "windowID", "tabIndex", "deadlineUptime"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else {
            throw ValidationError("Invalid native upload request schema")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func makeScript() -> String {
        NativeUploadScript.make(selector: selector, path: path, fileSize: fileSize,
            modificationTimeMilliseconds: modificationTimeMilliseconds, clipboardChangeCount: clipboardChangeCount,
            window: window, timeout: timeout, nonce: nonce, windowID: windowID, tabIndex: tabIndex,
            deadlineUptime: deadlineUptime)
    }
}

enum NativeUploadWorkerValidation {
    static func validate(_ request: NativeUploadRequest, expectedImage: String, currentImage: String,
                         parentExecutable: String?, executable: String, now: Double) throws {
        guard expectedImage.utf8.count == 32,
              expectedImage.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expectedImage == currentImage,
              let parentExecutable, parentExecutable == executable, executable.hasPrefix("/") else {
            throw ValidationError("Native upload worker requires its matching parent executable")
        }
        let safeInteger: Int64 = 9_007_199_254_740_991
        guard request.version == 1,
              !request.selector.isEmpty, request.selector.utf8.count <= 65_536,
              !request.selector.contains("\0"),
              request.path.hasPrefix("/"), request.path != "/", request.path.utf8.count <= 4096,
              !request.path.contains("\0"), URL(fileURLWithPath: request.path).standardizedFileURL.path == request.path,
              (0...safeInteger).contains(request.fileSize),
              (-safeInteger...safeInteger).contains(request.modificationTimeMilliseconds),
              request.clipboardChangeCount >= 0, request.clipboardChangeCount <= Int(Int32.max),
              request.window.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true,
              request.windowID > 0, request.windowID <= Int(UInt32.max),
              request.tabIndex.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true,
              request.timeout.isFinite, (0.001...86_400).contains(request.timeout),
              UUID(uuidString: request.nonce) != nil,
              now.isFinite, now >= 0, request.deadlineUptime.isFinite,
              request.deadlineUptime > now, request.deadlineUptime - now <= request.timeout else {
            throw ValidationError("Invalid or expired native upload transaction")
        }
    }
}

enum NativeUploadWorkerContext {
    @TaskLocal static var request: NativeUploadRequest?

    /// Pure callback boundary, so rejection can be exercised without touching AX
    /// or the user's pasteboard. Rechecking after the probe also rejects changes
    /// observed during its bounded read.
    static func selection(windowID: Int, request: NativeUploadRequest?, now: () -> Double,
                          clipboardCount: () -> Int, probe: (Int, String, Double) -> String) -> String {
        guard let request, windowID == request.windowID else { return "OWNER_CHANGED" }
        guard now() < request.deadlineUptime else { return "DEADLINE" }
        guard clipboardCount() == request.clipboardChangeCount else { return "CLIPBOARD_CHANGED" }
        let result = probe(windowID, request.path, request.deadlineUptime)
        guard now() < request.deadlineUptime else { return "DEADLINE" }
        guard clipboardCount() == request.clipboardChangeCount else { return "CLIPBOARD_CHANGED" }
        return result
    }

    static func confirmationLine(_ title: String) -> String? {
        guard ["Open", "Upload", "打開", "開啟", "上傳"].contains(title) else { return nil }
        return "confirming file dialog: pressing named button \"\(title)\"\n"
    }
}

@MainActor
@objc(SBNativeUploadBridge)
final class SBNativeUploadBridge: NSObject {
    @objc(selectionForWindow:)
    static func selectionForWindow(_ windowID: Int) -> NSString {
        MainActor.preconditionIsolated()
        return NativeUploadWorkerContext.selection(windowID: windowID, request: NativeUploadWorkerContext.request,
            now: { ProcessInfo.processInfo.systemUptime },
            clipboardCount: { NSPasteboard.general.changeCount }, probe: NativeUploadSelectionProbe.check) as NSString
    }

    @objc(logConfirmation:)
    static func logConfirmation(_ title: String) {
        MainActor.preconditionIsolated()
        guard let request = NativeUploadWorkerContext.request,
              ProcessInfo.processInfo.systemUptime < request.deadlineUptime,
              NSPasteboard.general.changeCount == request.clipboardChangeCount,
              let line = NativeUploadWorkerContext.confirmationLine(title) else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Runtime script failures must not render ArgumentParser's usage footer: the
/// parent recognizes the final AppleScript sentinel to preserve its public error.
struct NativeUploadWorkerRuntimeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct NativeUploadWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__native-upload", shouldDisplay: false)
    @Argument var encodedRequest: String
    @Argument var expectedImageIdentifier: String

    mutating func run() async throws {
        let request = try NativeUploadRequest.decode(encodedRequest)
        let currentImage = try MCPWorkerContext.currentImageIdentifier()
        let executable = try MCPWorkerContext.executableURL().resolvingSymlinksInPath().path
        let parentPID = getppid()
        guard parentPID > 1 else { throw ValidationError("Native upload worker has no owning parent") }
        var path = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(parentPID, &path, UInt32(path.count))
        let parentExecutable: String? = length > 0
            ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        guard getppid() == parentPID else { throw ValidationError("Native upload worker parent changed") }
        try NativeUploadWorkerValidation.validate(request, expectedImage: expectedImageIdentifier,
            currentImage: currentImage, parentExecutable: parentExecutable, executable: executable,
            now: ProcessInfo.processInfo.systemUptime)
        try await MainActor.run {
            guard getppid() == parentPID, ProcessInfo.processInfo.systemUptime < request.deadlineUptime else {
                throw ValidationError("Native upload worker expired or lost its parent")
            }
            try NativeUploadWorkerContext.$request.withValue(request) {
                // Fixed builder only: no external source, no worker clipboard lease.
                guard let script = NSAppleScript(source: request.makeScript()) else {
                    throw ValidationError("Cannot construct native upload script")
                }
                var details: NSDictionary?
                _ = script.executeAndReturnError(&details)
                if let details { throw Self.runtimeError(details) }
            }
        }
    }

    static func runtimeError(_ details: NSDictionary) -> any Error {
        NativeUploadWorkerRuntimeError(message: scriptError(details))
    }

    /// Preserve the marker's established suffix for the parent's element-not-found
    /// mapping; do not confuse compiler errors with that runtime sentinel.
    static func scriptError(_ details: NSDictionary) -> String {
        let message = details[NSAppleScript.errorMessage] as? String ?? "Native upload script failed"
        let number = details[NSAppleScript.errorNumber] as? Int ?? -2700
        return "execution error: \(message) (\(number))"
    }
}
