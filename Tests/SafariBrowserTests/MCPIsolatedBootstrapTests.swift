import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPIsolatedBootstrapTests: XCTestCase, @unchecked Sendable {
    private var helper: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser") }

    func testPendingTerminationCheckRejectsBackgroundThread() async {
        let refused: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard pthread_main_np() == 0 else { continuation.resume(returning: false); return }
                do {
                    try MCPWorkerSpawn.checkPendingTermination()
                    continuation.resume(returning: false)
                } catch MCPWorkerLaunchError.supervisorContext {
                    continuation.resume(returning: true)
                } catch { continuation.resume(returning: false) }
            }
        }
        XCTAssertTrue(refused, "A background thread cannot establish the initial thread's pending TERM state")
    }

    func testFixedContextRejectsMalformedParentDeadlineAndFraming() throws {
        // Independent literal: SBI1 magic little-endian, parent 42, deadline1.0.
        let literal = Data([0x31, 0x49, 0x42, 0x53, 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f])
        let parsed = try MCPIsolatedBootstrap.decodeContext(literal)
        XCTAssertEqual(parsed.parent, 42)
        XCTAssertEqual(parsed.deadline, 1)
        XCTAssertEqual(try MCPIsolatedBootstrap.context(parent: 42, deadline: 1), literal)
        for bytes in [Data(), Data(literal.dropLast()), literal + Data([0])] {
            XCTAssertThrowsError(try MCPIsolatedBootstrap.decodeContext(bytes))
        }
        for parent in [UInt32(0), 1, UInt32.max] {
            var bad = literal, little = parent.littleEndian
            withUnsafeBytes(of: &little) { bad.replaceSubrange(4..<8, with: $0) }
            XCTAssertThrowsError(try MCPIsolatedBootstrap.decodeContext(bad))
        }
        for deadline in [Double.nan, .infinity, -.infinity, 0, -1] {
            var bad = literal, bits = deadline.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bad.replaceSubrange(8..<16, with: $0) }
            XCTAssertThrowsError(try MCPIsolatedBootstrap.decodeContext(bad))
        }
        var wrongMagic = literal; wrongMagic[0] ^= 1
        XCTAssertThrowsError(try MCPIsolatedBootstrap.decodeContext(wrongMagic))
    }

    func testExpiredSpawnDeadlineDoesNotCreateAChild() {
        do {
            let child = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], environment: [:], descriptors: [:], deadline: ProcessInfo.processInfo.systemUptime - 1)
            _ = child.retire()
            XCTFail("An expired dispatch must not create a child after allocating its arguments")
        } catch {
            guard case MCPWorkerLaunchError.invalidConfiguration = error else { return XCTFail("Unexpected failure: \(error)") }
        }
    }

    /// Independent reference: ask the kernel to execute the original argv/env,
    /// without any supervisor, private transport, or runner admission estimate.
    private func originalAdmission(arguments: [String], environment: [String: String]) throws -> Int32 {
        let executable = helper.path
        let argv = ([executable, "__mcp-exec"] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&child, executable, nil, nil, a.baseAddress!, e.baseAddress!)
        } }
        if result == 0 {
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(child, &status, 0) } while waited < 0 && errno == EINTR
            XCTAssertEqual(waited, child)
            XCTAssertEqual(status, 0, "Accepted original CLI must actually execute successfully")
        }
        return result
    }

    func testSupervisionPreservesExactKernelArgumentAndEnvironmentAdmission() async throws {
        let image = try MCPExecutableIdentity.readImage(at: helper, architecture: MCPExecutableIdentity.currentArchitecture())
        for environmentBytes in [0, 8192] {
            let environment = ["OWNED_PADDING": String(repeating: "e", count: environmentBytes)]
            var originalEnvironment = environment
            originalEnvironment["SAFARI_BROWSER_MCP_DIRECT"] = "1"
            originalEnvironment["SAFARI_BROWSER_MCP_IMAGE_ID"] = image
            var accepted = 0, rejected = sysconf(_SC_ARG_MAX) + 4096
            XCTAssertEqual(try originalAdmission(arguments: ["wait", String(repeating: "0", count: rejected)], environment: originalEnvironment), E2BIG)
            while rejected - accepted > 1 {
                let count = (accepted + rejected) / 2
                let error = try originalAdmission(arguments: ["wait", String(repeating: "0", count: count)], environment: originalEnvironment)
                if error == 0 { accepted = count }
                else { XCTAssertEqual(error, E2BIG); rejected = count }
            }
            XCTAssertGreaterThan(accepted, 0)
            for (count, succeeds) in [(accepted, true), (rejected, false)] {
                // The timeout is not what this test checks (the exact argv/environment admission is), so it is
                // wide. It was 3 s and a full run once failed with `Command timed out` (#258): in that run every
                // spawn with a ~1 MiB argv took about 1.2 s instead of ~3 ms (this test 60.9 s instead of
                // 1.25 s; the other tests that spawn with a large argv were 8 to 31 times slower, ordinary
                // spawns were not), and no setting of the same machine afterwards reproduced it. 30 s is about
                // five times the slowest run seen. A supervised run that really hangs now fails after 30 s.
                let result = await MCPProcessRunner(executable: helper, environment: environment, timeout: 30)
                    .run(arguments: ["wait", String(repeating: "0", count: count)], input: Data(), expectedImage: image)
                if succeeds {
                    XCTAssertEqual(result.exitCode, 0, "Original kernel admitted exactly this argv/environment")
                    XCTAssertNil(result.failure, String(decoding: result.stderr, as: UTF8.self))
                } else {
                    XCTAssertNil(result.exitCode)
                    XCTAssertTrue(result.failure?.contains(String(cString: strerror(E2BIG))) == true)
                }
            }
        }
    }
}
