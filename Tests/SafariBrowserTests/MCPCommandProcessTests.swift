import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPCommandProcessTests: XCTestCase {
    private func fixture(_ script: String, isolated: Bool = true) -> MCPCommandProcess {
        let child = MCPCommandProcess(useMCPIsolation: isolated)
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", script]
        return child
    }

    func testMCPInheritsGroupButOrdinaryFoundationRemainsSeparate() throws {
        for isolated in [true, false] {
            let output = Pipe()
            let child = fixture("import os; print(os.getpgrp())", isolated: isolated)
            child.standardOutput = output
            try child.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            let group = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            if isolated { XCTAssertEqual(group, getpgrp()) }
            else { XCTAssertNotEqual(group, getpgrp()) }
            XCTAssertEqual(child.terminationStatus, 0)
        }
    }

    func testLiteralArgvEnvironmentAndPipes() throws {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let child = fixture("import sys,os; sys.stdout.buffer.write(sys.stdin.buffer.read()); print(sys.argv[1],file=sys.stderr); print(os.environ['MCP_FIXTURE'],file=sys.stderr); sys.exit(7)")
        child.arguments!.append("--literal $() ' a b")
        child.environment = ["MCP_FIXTURE": "injected"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        input.fileHandleForWriting.write(Data([0, 10, 255]))
        try input.fileHandleForWriting.close()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data([0, 10, 255]))
        XCTAssertEqual(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "--literal $() ' a b\ninjected\n")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 7)
        XCTAssertFalse(child.isRunning)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child.processIdentifier, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testForceKillOnlyOwnedChildAndRepeatedSignalsAreSafe() throws {
        let output = Pipe()
        let child = fixture("import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(30)")
        child.standardOutput = output
        try child.run()
        XCTAssertEqual(String(decoding: try XCTUnwrap(output.fileHandleForReading.read(upToCount: 6)), as: UTF8.self), "ready\n")
        child.terminate()
        child.forceKill()
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertNotEqual(child.terminationStatus, 0)
        for _ in 0..<10 { child.terminate(); child.forceKill(); child.waitUntilExit() }
    }

    func testNilMeansNullDeviceAndFileHandleOutputWorks() throws {
        let output = Pipe()
        let child = fixture("import sys; print(len(sys.stdin.buffer.read()))")
        child.standardInput = nil
        child.standardOutput = output.fileHandleForWriting
        try child.run()
        try output.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "0\n")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testUnrelatedDescriptorsDoNotLeakIntoChild() throws {
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(fcntl(descriptor, F_SETFD, 0), 0)
        let output = Pipe()
        let child = fixture("import os,sys;\ntry: os.fstat(int(sys.argv[1])); print('leaked')\nexcept OSError: print('closed')")
        child.arguments!.append(String(descriptor))
        child.standardOutput = output
        try child.run()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "closed\n")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testConcurrentWaitAndSignalsShareReapingOwnership() throws {
        for _ in 0..<12 {
            let child = fixture("pass")
            try child.run()
            let work = DispatchGroup()
            work.enter()
            DispatchQueue.global().async {
                child.waitUntilExit()
                work.leave()
            }
            work.enter()
            DispatchQueue.global().async {
                for _ in 0..<20 { child.terminate(); child.forceKill() }
                work.leave()
            }
            XCTAssertEqual(work.wait(timeout: .now() + 3), .success)
            XCTAssertFalse(child.isRunning)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(child.processIdentifier, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }

    func testMissingExecutableUnsupportedStreamAndNULFailBeforeLaunch() {
        let missing = fixture("pass")
        missing.executableURL = URL(fileURLWithPath: "/no/such/mcp-program")
        XCTAssertThrowsError(try missing.run())
        let stream = fixture("pass")
        stream.standardOutput = "bad stream"
        XCTAssertThrowsError(try stream.run())
        let nul = fixture("pass\0")
        XCTAssertThrowsError(try nul.run())
    }
    func testExternalFixtureCannotWriteDelayedEffectAfterTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late-effect")
        let output = Pipe()
        let child = fixture("import pathlib,sys,time; print('ready',flush=True); time.sleep(0.3); pathlib.Path(sys.argv[1]).write_text('late')")
        child.arguments!.append(marker.path)
        child.standardOutput = output
        try child.run()
        XCTAssertEqual(String(decoding: try XCTUnwrap(output.fileHandleForReading.read(upToCount: 6)), as: UTF8.self), "ready\n")
        child.terminate()
        child.waitUntilExit()
        XCTAssertNotEqual(child.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

}
