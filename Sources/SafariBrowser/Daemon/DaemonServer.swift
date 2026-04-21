import Foundation
import Darwin

/// Long-running per-user daemon that serves `safari-browser` requests over a
/// Unix domain socket, holding pre-compiled `NSAppleScript` handles warm.
///
/// Task 2.1 implements the IPC core: Unix socket binding, JSON-lines framing,
/// method dispatch, and graceful shutdown. Handlers are registered by method
/// name and receive params as a `Data` blob (the JSON subtree under the
/// incoming request's `"params"` key) and return `Data` (the JSON subtree to
/// place under the response's `"result"` key).
///
/// Method handlers that speak to Safari arrive in later tasks (3.1 / 4.1 / 7.1).
enum DaemonServer {
    /// Error codes surfaced in JSON-lines responses.
    enum ErrorCode: String {
        case parseError
        case methodNotFound
        case handlerError
    }

    /// Running daemon instance. Construct with `init()`, register handlers
    /// with `register(_:handler:)`, start with `start(socketPath:)`, and
    /// stop with `stop()`.
    actor Instance {
        typealias MethodHandler = @Sendable (Data) async throws -> Data

        private var handlers: [String: MethodHandler] = [:]
        private var listenerFd: Int32 = -1
        private var acceptTask: Task<Void, Never>?
        private var socketPath: String?
        private var connectionTasks: [Task<Void, Never>] = []

        init() {}

        /// Register a method handler. Overwrites any previous handler for the same method.
        func register(_ method: String, handler: @escaping MethodHandler) {
            handlers[method] = handler
        }

        /// Bind the Unix socket, start listening, and kick off the accept loop.
        /// Throws `DaemonError` on bind/listen failure.
        func start(socketPath: String) async throws {
            guard listenerFd < 0 else { return } // idempotent — already started

            // Remove any stale socket left from a crashed prior run.
            unlink(socketPath)

            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw DaemonError.bindFailed("socket() failed: errno=\(errno)")
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathMaxBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1
            let pathBytes = Array(socketPath.utf8)
            if pathBytes.count > pathMaxBytes {
                close(fd)
                throw DaemonError.bindFailed("socket path too long: \(socketPath.count) > \(pathMaxBytes)")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in pathBytes.enumerated() {
                    buf[i] = b
                }
                buf[pathBytes.count] = 0
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, addrLen)
                }
            }
            if bindRC != 0 {
                close(fd)
                throw DaemonError.bindFailed("bind() failed: errno=\(errno)")
            }
            if listen(fd, 16) != 0 {
                close(fd)
                unlink(socketPath)
                throw DaemonError.bindFailed("listen() failed: errno=\(errno)")
            }

            self.listenerFd = fd
            self.socketPath = socketPath

            // Snapshot handlers once per connection accepts; registrations
            // after start() land on future connections via latest snapshot
            // fetched at dispatch time.
            let instance = self
            self.acceptTask = Task.detached(priority: .userInitiated) {
                await Self.acceptLoop(listenerFd: fd, instance: instance)
            }
        }

        /// Stop accepting new connections, close existing connections,
        /// and remove the socket file.
        func stop() async {
            if listenerFd >= 0 {
                close(listenerFd)
                listenerFd = -1
            }
            acceptTask?.cancel()
            acceptTask = nil
            for task in connectionTasks {
                task.cancel()
            }
            connectionTasks.removeAll()
            if let path = socketPath {
                unlink(path)
                socketPath = nil
            }
        }

        // MARK: - Internal dispatch (actor-isolated)

        fileprivate func lookupHandler(_ method: String) -> MethodHandler? {
            handlers[method]
        }

        fileprivate func trackConnection(_ task: Task<Void, Never>) {
            connectionTasks.append(task)
        }

        // MARK: - Accept loop

        private static func acceptLoop(listenerFd: Int32, instance: Instance) async {
            while !Task.isCancelled {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { p -> Int32 in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(listenerFd, sa, &clientLen)
                    }
                }
                if clientFd < 0 {
                    // EBADF on stop(), EINTR transient — just exit loop; stop() will have unlinked.
                    return
                }
                let handlerTask = Task.detached(priority: .userInitiated) {
                    await Self.serveConnection(clientFd: clientFd, instance: instance)
                }
                await instance.trackConnection(handlerTask)
            }
        }

        private static func serveConnection(clientFd: Int32, instance: Instance) async {
            defer { close(clientFd) }
            while !Task.isCancelled {
                guard let line = readLine(fd: clientFd) else { return }
                let response = await dispatchLine(line: line, instance: instance)
                if !writeLine(fd: clientFd, line: response) { return }
            }
        }

        private static func dispatchLine(line: Data, instance: Instance) async -> Data {
            // Parse the incoming request envelope.
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: line, options: [])
            } catch {
                return encodeError(requestId: nil, code: .parseError, message: "invalid JSON: \(error)")
            }
            guard let obj = parsed as? [String: Any] else {
                return encodeError(requestId: nil, code: .parseError, message: "request must be JSON object")
            }
            let requestId = obj["requestId"]
            guard let method = obj["method"] as? String else {
                return encodeError(requestId: requestId, code: .parseError, message: "missing 'method'")
            }
            let paramsValue: Any = obj["params"] ?? [:]
            let paramsData: Data
            do {
                paramsData = try JSONSerialization.data(withJSONObject: paramsValue, options: [])
            } catch {
                return encodeError(requestId: requestId, code: .parseError, message: "unserialisable params")
            }

            guard let handler = await instance.lookupHandler(method) else {
                return encodeError(requestId: requestId, code: .methodNotFound, message: "no handler: \(method)")
            }

            do {
                let resultData = try await handler(paramsData)
                return encodeResult(requestId: requestId, resultData: resultData)
            } catch {
                return encodeError(requestId: requestId, code: .handlerError, message: "\(error)")
            }
        }

        // MARK: - Response encoding

        private static func encodeResult(requestId: Any?, resultData: Data) -> Data {
            let resultValue: Any = (try? JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed])) ?? NSNull()
            let envelope: [String: Any] = [
                "requestId": requestId ?? NSNull(),
                "result": resultValue,
            ]
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
        }

        private static func encodeError(requestId: Any?, code: ErrorCode, message: String) -> Data {
            let envelope: [String: Any] = [
                "requestId": requestId ?? NSNull(),
                "error": ["code": code.rawValue, "message": message] as [String: Any],
            ]
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
        }

        // MARK: - Line I/O (POSIX)

        private static func readLine(fd: Int32) -> Data? {
            var bytes: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 1)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, 1)
                }
                if n <= 0 {
                    if bytes.isEmpty { return nil }
                    break
                }
                if buf[0] == 0x0A { break }
                bytes.append(buf[0])
            }
            return Data(bytes)
        }

        private static func writeLine(fd: Int32, line: Data) -> Bool {
            var payload = Data(line)
            payload.append(0x0A)
            return payload.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                var written = 0
                while written < rawBuf.count {
                    let n = write(fd, base.advanced(by: written), rawBuf.count - written)
                    if n <= 0 { return false }
                    written += n
                }
                return true
            }
        }
    }

    enum DaemonError: Error, CustomStringConvertible {
        case bindFailed(String)

        var description: String {
            switch self {
            case .bindFailed(let reason): return "daemon bind failed: \(reason)"
            }
        }
    }
}
