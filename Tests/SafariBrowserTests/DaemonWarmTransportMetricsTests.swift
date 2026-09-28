import Foundation
import XCTest
@testable import SafariBrowser

/// Same owned, Safari-free fixture can run on the pre-#199 implementation.
final class DaemonWarmTransportMetricsTests: XCTestCase {
    func testOwnedWarmRPCLatency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("b199-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server = DaemonServer.Instance(), name = "owned"
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: directory) }
        await server.register("fixture.echo") { _ in Data("true".utf8) }
        try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: name))
        var samples: [Double] = []
        for index in 0..<45 {
            let begin = ContinuousClock.now
            let value = try await DaemonClient.sendRequest(name: name, method: "fixture.echo", params: Data("{}".utf8),
                requestId: index, timeout: 2, socketDir: directory.path)
            let elapsed = begin.duration(to: .now).components
            XCTAssertEqual(value, Data("true".utf8))
            if index >= 5 { samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
        }
        let sorted = samples.sorted()
        let result: [String: Any] = [
            "samples": samples, "sampleCount": samples.count,
            "medianMilliseconds": (sorted[19] + sorted[20]) / 2,
            "p95Milliseconds": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("METRIC199.warm " + String(decoding: data, as: UTF8.self))
        await server.stop()
    }
}
