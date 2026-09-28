import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPWorkerSupervisorTests: XCTestCase {
    private static let fixture: Result<URL, Error> = Result {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", "-o", executable.path,
                           root.appendingPathComponent("Sources/SafariBrowser/MCP/MCPWorkerSupervisor.swift").path,
                           root.appendingPathComponent("Sources/SafariBrowser/MCP/MCPWorkerWire.swift").path,
                           root.appendingPathComponent("Tests/Fixtures/MCPWorkerSupervisorFixture.swift").path]
        let log = directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        build.standardOutput = output; build.standardError = output
        try build.run(); build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            throw NSError(domain: "Fixture build", code: Int(build.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: (try? String(contentsOf: log, encoding: .utf8)) ?? "No build log"])
        }
        return executable
    }

    private func launch(_ mode: String = "wait") throws -> MCPWorkerPair {
        try MCPWorkerPair.launch(executable: Self.fixture.get(), arguments: ["supervisor", "worker", mode],
                                 environment: ProcessInfo.processInfo.environment)
    }

    private func read(_ fd: Int32, until count: Int? = nil, timeout: TimeInterval = 3) -> Data {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 10) <= 0 { continue }
            let amount = Darwin.read(fd, &bytes, bytes.count)
            if amount <= 0 { break }
            data.append(contentsOf: bytes.prefix(amount))
            if let count, data.count >= count { break }
            if count == nil, data.contains(10) { break }
        }
        return data
    }

    private func report(_ pair: MCPWorkerPair) throws -> [String: Int32] {
        let data = read(pair.control)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int32])
    }

    private func hasExited(_ pid: pid_t, timeout: TimeInterval = 3) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var info = proc_bsdinfo()
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if count == 0, errno == ESRCH { return true }
            if count == MemoryLayout<proc_bsdinfo>.size, info.pbi_status == SZOMB { return true }
            usleep(10_000)
        }
        return false
    }

    private func waitForState(_ pid: pid_t, state: Int32) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
               info.pbi_status == UInt32(state) { return true }
            usleep(10_000)
        }
        return false
    }

    func testShortCleanupDeadlineRetainsReservationUntilLaterRetirement() throws {
        let pair = try launch("ignore-term")
        defer { _ = pair.child.retire() }
        let worker = try XCTUnwrap(try report(pair)["pid"])
        XCTAssertEqual(kill(-pair.child.pid, SIGSTOP), 0) // locally owned and unreaped
        XCTAssertTrue(waitForState(pair.child.pid, state: SSTOP))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(pair.child.retire(timeout: 0.005), .pending)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
        // It may already be a zombie. The invariant is unreaped ownership,
        // not continued liveness after requesting termination.
        XCTAssertNoThrow(try pair.child.observe())
        guard case .reaped = pair.child.retire() else { return XCTFail("Later retirement must finish") }
        XCTAssertTrue(hasExited(worker))
    }

    func testRepeatedChannelCloseDoesNotCloseAReusedDescriptor() throws {
        let pair = try launch()
        defer { _ = pair.child.retire() }
        _ = try report(pair)
        let former = pair.control
        pair.closeChannels()
        let null = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(null, 0)
        defer { Darwin.close(null) }
        // Allocate atomically, never dup2 onto a slot another thread may have
        // acquired after close. Only descriptors returned to this test are owned.
        let replacement = null == former ? null : fcntl(null, F_DUPFD_CLOEXEC, former)
        XCTAssertEqual(replacement, former)
        defer { if replacement != null, replacement >= 0 { Darwin.close(replacement) } }
        pair.closeChannels()
        XCTAssertGreaterThanOrEqual(fcntl(replacement, F_GETFD), 0)
        guard case .reaped = pair.child.retire() else { return XCTFail("Owner still must reap after channels close") }
    }

    func testSupervisorReleasesBootstrapStreamsWhileWorkerRemainsAlive() throws {
        let pair = try launch("close-bootstrap")
        defer { _ = pair.child.retire() }
        _ = try report(pair)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var eof = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: pair.diagnostics, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 10) <= 0 { continue }
            var byte: UInt8 = 0
            if Darwin.read(pair.diagnostics, &byte, 1) == 0 { eof = true; break }
        }
        XCTAssertTrue(eof, "Supervisor must not retain worker bootstrap output")
        XCTAssertEqual(try pair.child.observe(), .running)
    }

    func testInvalidParentDoesNotStartWorker() throws {
        for mode in ["invalid-parent", "wrong-parent"] {
            let pair = try launch(mode)
            defer { _ = pair.child.retire() }
            XCTAssertTrue(read(pair.control).isEmpty)
            XCTAssertTrue(hasExited(pair.child.pid))
            guard case .reaped(let status) = pair.child.retire() else { return XCTFail("Rejected helper must exit") }
            XCTAssertEqual(status, 86 << 8)
            XCTAssertTrue(read(pair.status, until: 12).isEmpty)
        }
    }

    func testLaunchWithClosedStdioDoesNotClobberPrivateSources() throws {
        var output = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&output), 0)
        defer { Darwin.close(output[0]); Darwin.close(output[1]) }
        let owner = try MCPWorkerSpawn.child(executable: Self.fixture.get(), arguments: ["closed-stdio-owner"],
            environment: ProcessInfo.processInfo.environment, descriptors: [3: output[1]])
        defer { _ = owner.retire() }
        let data = read(output[0])
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int32])
        XCTAssertEqual(message["ppid"], message["group"])
        XCTAssertNotEqual(message["pid"], message["group"])
        XCTAssertEqual(message["fd4Open"], 0)
        XCTAssertEqual(message["fd5Open"], 0)
        XCTAssertTrue(hasExited(try XCTUnwrap(message["pid"])))
    }

    func testWorkerInheritsSupervisorGroupButNotLifetimeOrStatusDescriptors() throws {
        let pair = try launch()
        defer { _ = pair.child.retire() }
        let message = try report(pair)
        XCTAssertEqual(message["ppid"], pair.child.pid)
        XCTAssertEqual(message["group"], pair.child.pid)
        XCTAssertNotEqual(message["pid"], pair.child.pid)
        XCTAssertEqual(message["fd4Open"], 0)
        XCTAssertEqual(message["fd5Open"], 0)
        XCTAssertEqual(try pair.child.observe(), .running)
        pair.closeLifetime()
        XCTAssertTrue(hasExited(try XCTUnwrap(message["pid"])))
        guard case .reaped = pair.child.retire() else { return XCTFail("Supervisor must be reaped: \(pair.child.retire())") }
    }

    func testControllerDeathKillsStoppedWorkerAndLeavesOtherOwnedGroupAlive() throws {
        let unrelated = try launch()
        defer { _ = unrelated.child.retire() }
        let unrelatedWorker = try XCTUnwrap(try report(unrelated)["pid"])
        let pair = try launch("stop-descendant")
        defer { _ = pair.child.retire() }
        let message = try report(pair)
        let worker = try XCTUnwrap(message["pid"])
        let descendant = try XCTUnwrap(message["descendant"])
        XCTAssertTrue(waitForState(worker, state: SSTOP), "Fixture must actually be stopped before controller dies")
        XCTAssertFalse(MCPWorkerGroup.containsOnly(group: pair.child.pid, allowed: [pair.child.pid, worker]))
        // A separate process inherits the lease writer; this custodian closes
        // its only copy before killing that controller. The production parent
        // validation still refers to the custodian that owns the supervisor.
        var ready = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&ready), 0)
        defer { Darwin.close(ready[0]); Darwin.close(ready[1]) }
        let controller = try MCPWorkerSpawn.child(executable: Self.fixture.get(), arguments: ["controller"],
            environment: ProcessInfo.processInfo.environment, descriptors: [3: pair.lifetimeWriter, 4: ready[1]])
        defer { _ = controller.retire() }
        XCTAssertEqual(read(ready[0], until: 5), Data("ready".utf8))
        pair.closeLifetime()
        XCTAssertEqual(try pair.child.observe(), .running)
        guard case .reaped(let controllerStatus) = controller.retire() else { return XCTFail("Controller retirement failed: \(controller.retire())") }
        XCTAssertEqual(controllerStatus & 0x7f, SIGKILL)
        XCTAssertTrue(hasExited(worker), "Check actual stopped worker, not just supervisor")
        XCTAssertTrue(hasExited(descendant), "Ordinary descendants must also terminate")
        XCTAssertEqual(try unrelated.child.observe(), .running)
        XCTAssertFalse(hasExited(unrelatedWorker, timeout: 0.02))
        guard case .reaped = pair.child.retire() else { return XCTFail("Supervisor retirement failed") }
        // No signal may follow successful reap; repeated retirement is stable.
        guard case .reaped = pair.child.retire() else { return XCTFail("Repeated retirement changed ownership") }
    }

    func testWorkerExitReportsActualWorkerStatusBeforeSupervisorTerminates() throws {
        let pair = try launch("exit")
        defer { _ = pair.child.retire() }
        let worker = try XCTUnwrap(try report(pair)["pid"])
        let record = try MCPWorkerWire.TerminationRecord.decode(read(pair.status, until: 12))
        XCTAssertEqual(record.workerPID, worker)
        XCTAssertEqual(record.rawWaitStatus, 23 << 8)
        XCTAssertTrue(hasExited(pair.child.pid))
        guard case .reaped(let status) = pair.child.retire() else { return XCTFail("No supervisor status: \(pair.child.retire())") }
        XCTAssertEqual(status & 0x7f, SIGKILL, "Never substitute supervisor status for CLI status")
    }

    func testLostReservationStopsFurtherCleanupAndInvalidArgumentsNeverSpawn() throws {
        let child = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            environment: [:], descriptors: [:])
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child.pid, &status, 0), child.pid) // deliberately violate sole-reaper ownership
        XCTAssertThrowsError(try child.observe())
        XCTAssertEqual(child.retire(), .ownershipLost)
        XCTAssertEqual(child.retire(), .ownershipLost)
        XCTAssertThrowsError(try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["\0"], environment: [:], descriptors: [:]))
        XCTAssertThrowsError(try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], environment: ["bad=key": "value"], descriptors: [:]))
    }
}
