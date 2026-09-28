import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonConnectionMemoryTests: XCTestCase {
    private func residentKiB() throws -> Int {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(getpid())]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testLargeRequestChurnRetiresWorkAndRecordsPhysicalMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m199-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server = DaemonServer.Instance(), name = "owned", bytes = 2 * 1024 * 1024
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: directory) }
        await server.register("fixture.memory") { params in
            let object = try JSONSerialization.jsonObject(with: params) as? [String: String]
            return Data(object?["source"]?.utf8.count == bytes ? "true".utf8 : "false".utf8)
        }
        try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: name))
        let params = try JSONSerialization.data(withJSONObject: ["source": String(repeating: "x", count: bytes)])
        var samples: [[String: Int]] = []
        for index in 0..<36 {
            let result = try await DaemonClient.sendRequest(name: name, method: "fixture.memory", params: params,
                requestId: index, timeout: 5, socketDir: directory.path)
            XCTAssertEqual(result, Data("true".utf8))
            for _ in 0..<200 {
                if await server.trackedConnectionCount == 0, await server.activeOperationCount == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let connections = await server.trackedConnectionCount
            let operations = await server.activeOperationCount
            XCTAssertEqual(connections, 0)
            XCTAssertEqual(operations, 0)
            if [3, 11, 19, 35].contains(index) {
                samples.append(["completedRequests": index + 1, "rssKiB": try residentKiB(),
                                "connections": connections, "operations": operations])
            }
        }
        let evidence: [String: Any] = ["payloadBytes": bytes, "samples": samples,
            "interpretation": "RSS observations; allocator capacity and whole-process bounds are not inferred"]
        print("METRIC199.memory " + String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
        await server.stop()
    }
}
