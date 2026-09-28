import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    enum WorkerMode: String, ExpressibleByArgument { case persistent, isolated }
    @Option(help: "Worker execution mode: persistent reuses isolated CLI workers; isolated starts one per call")
    var workerMode: WorkerMode = .persistent
    @Option(help: "Seconds before an idle persistent worker exits (0.001–86400; persistent mode only)")
    var workerIdleTimeout: Double = 30

    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the existing CLI tools over MCP stdio"
    )
    @Option(help: "Maximum seconds per tool invocation (0.001–86400; cancellation cannot undo prior effects)")
    var timeout: Double = 300

    func validate() throws {
        guard timeout.isFinite, timeout >= 0.001, timeout <= 86400 else {
            throw ValidationError("--timeout must be finite and between 0.001 and 86400 seconds")
        }
        guard workerIdleTimeout.isFinite, (0.001...86400).contains(workerIdleTimeout) else {
            throw ValidationError("--worker-idle-timeout must be finite and between 0.001 and 86400 seconds")
        }
    }

    mutating func run() async throws {
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        let identity = try MCPWorkerContext.currentImageIdentifier()
        let executable = try MCPWorkerContext.executableURL()
        let runner: any MCPCommandRunning
        switch workerMode {
        case .persistent:
            runner = MCPPersistentRunner(executable: executable, timeout: timeout, idleTimeout: workerIdleTimeout)
        case .isolated:
            runner = MCPProcessRunner(executable: executable, timeout: timeout)
        }
        let reader = try MCPStdioReader(fileDescriptor: STDIN_FILENO)
        let writer: MCPStdioWriter
        do { writer = try MCPStdioWriter(fileDescriptor: STDOUT_FILENO) }
        catch { await reader.close(); throw error }
        let pump = try MCPResponsePump(writer: writer, onFailure: { await reader.close() })
        let session = MCPSession(catalog: catalog, runner: runner, expectedImage: identity) { frame in
            do { try await pump.enqueue(frame) }
            catch { await reader.close(); throw error }
        }
        do {
            while let frame = try await reader.next() { try await session.receive(frame) }
            await session.shutdown()
            await reader.close()
            await pump.close()
            if let failure = await session.terminalFailure() { throw ValidationError(failure) }
            if let failure = await pump.failureDescription() { throw ValidationError(failure) }
        } catch {
            await session.shutdown()
            await reader.close()
            await pump.close()
            if let failure = await session.terminalFailure() { throw ValidationError(failure) }
            if let failure = await pump.failureDescription() { throw ValidationError(failure) }
            throw error
        }
    }
}
