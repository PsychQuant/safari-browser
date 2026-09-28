import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class CLIExecutionTests: XCTestCase, @unchecked Sendable {
    private struct Failure: LocalizedError { var errorDescription: String? { "sentinel" } }
    private struct Hidden: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "private", shouldDisplay: false)
    }
    func testCleanExitErrorAndSilentExitKeepStreamsNewlinesAndCodes() {
        let clean = CLIExecution.diagnostic(for: CleanExit.message("hello"))
        XCTAssertEqual(clean.exitCode, 0)
        XCTAssertEqual(clean.stream, .stdout)
        XCTAssertEqual(clean.bytes, Data("hello\n".utf8))
        let failure = CLIExecution.diagnostic(for: Failure())
        XCTAssertEqual(failure.exitCode, 1)
        XCTAssertEqual(failure.stream, .stderr)
        XCTAssertEqual(failure.bytes, Data("Error: sentinel\n".utf8))
        for code: Int32 in [0, 1, 17] {
            let silent = CLIExecution.diagnostic(for: ExitCode(code))
            XCTAssertEqual(silent.exitCode, code)
            XCTAssertTrue(silent.bytes.isEmpty)
        }
    }

    func testSuccessHelpValidationAndGluedHintReturnWithoutExitingProcess() async {
        var output = Data(), errors = Data()
        func write(_ stream: CLIExecution.Stream, _ bytes: Data) {
            if stream == .stdout { output.append(bytes) } else { errors.append(bytes) }
        }
        let wait = await CLIExecution.execute(arguments: ["wait", "0"], mode: .persistent,
                                              environment: [:], diagnosticSink: write)
        XCTAssertEqual(wait, 0)
        XCTAssertTrue(output.isEmpty); XCTAssertTrue(errors.isEmpty)
        let help = await CLIExecution.execute(arguments: ["wait", "--help"], mode: .persistent,
                                              environment: [:], diagnosticSink: write)
        XCTAssertEqual(help, 0)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("USAGE: safari-browser wait"))
        XCTAssertTrue(errors.isEmpty)
        output.removeAll()
        let bad = await CLIExecution.execute(arguments: ["wait", "--url value", "0"], mode: .persistent,
                                             environment: [:], diagnosticSink: write)
        XCTAssertEqual(bad, 64)
        XCTAssertTrue(output.isEmpty)
        let message = String(decoding: errors, as: UTF8.self)
        XCTAssertTrue(message.contains("Unknown option '--url value'"))
        XCTAssertTrue(message.contains("Hint: this looks like a flag and its value passed as a single argument."))
        XCTAssertTrue(message.hasSuffix("\n"))
        XCTAssertNil(MCPInvocationContext.current)
        XCTAssertNil(PerformanceTrace.context)
    }

    func testPersistentDispatchRejectsHiddenCommandsButStandaloneKeepsThem() throws {
        for command: any ParsableCommand in [Hidden(), MCPCommand(), MCPWorkerCommand()] {
            XCTAssertThrowsError(try CLIExecution.validate(command, mode: .persistent))
            XCTAssertNoThrow(try CLIExecution.validate(command, mode: .standalone))
        }
        XCTAssertNoThrow(try CLIExecution.validate(WaitCommand(), mode: .persistent))
    }

    func testRepeatedRequestsEmitDifferentTraceIDsAndNoInheritedCollector() async throws {
        var lines: [Data] = []
        for _ in 0..<2 {
            let code = await CLIExecution.execute(arguments: ["wait", "0"], mode: .persistent,
                environment: ["SAFARI_BROWSER_TRACE_TIMING": "1"], diagnosticSink: { stream, bytes in
                    XCTAssertEqual(stream, .stderr)
                    lines.append(bytes)
                })
            XCTAssertEqual(code, 0)
        }
        XCTAssertEqual(lines.count, 2)
        var identifiers = Set<String>()
        for line in lines {
            XCTAssertTrue(line.starts(with: Data(PerformanceTrace.prefix.utf8)))
            let body = line.dropFirst(PerformanceTrace.prefix.utf8.count)
            let summary = try JSONDecoder().decode(PerformanceTrace.Summary.self, from: Data(body))
            XCTAssertEqual(summary.status, .ok)
            XCTAssertEqual(summary.spans.first?.phase, .command)
            identifiers.insert(summary.requestID)
        }
        XCTAssertEqual(identifiers.count, 2)
    }
}
