import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonLogFileTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sink205-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func testCapturedWriterKeepsSinkAliveUntilLastOwnerRetires() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.log"), closes = Counter()
        var owner: DaemonLogFile? = try XCTUnwrap(DaemonLogFile(path: url.path, onClose: { closes.hit() }))
        weak var observed = owner
        var writer: (@Sendable (String) -> Void)? = { [file = owner!] line in file.write(line) }
        owner = nil
        XCTAssertNotNil(observed)
        XCTAssertEqual(closes.value, 0)
        writer?("late-owned-record\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "late-owned-record\n")
        writer = nil
        XCTAssertNil(observed)
        XCTAssertEqual(closes.value, 1)
    }

    func testNewFileIsPrivateCloseOnExecAndAppendsAcrossOwners() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.log")
        let old = try XCTUnwrap(DaemonLogFile(path: url.path))
        let flags = old.descriptorFlagsForTesting
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        old.write("old-first\n")
        let replacement = try XCTUnwrap(DaemonLogFile(path: url.path))
        replacement.write("new-record\n")
        old.write("old-late\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old-first\nnew-record\nold-late\n")
    }

    func testLateWriterKeepsOriginalInodeAfterRotation() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.log"), rotated = directory.appendingPathComponent("old.log")
        let old = try XCTUnwrap(DaemonLogFile(path: url.path))
        old.write("old-first\n")
        try FileManager.default.moveItem(at: url, to: rotated)
        let replacement = try XCTUnwrap(DaemonLogFile(path: url.path))
        replacement.write("new-record\n")
        old.write("old-late\n")
        XCTAssertEqual(try String(contentsOf: rotated, encoding: .utf8), "old-first\nold-late\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new-record\n")
    }

    func testConcurrentEntriesWithinOneSinkRemainWhole() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.log"), sink = try XCTUnwrap(DaemonLogFile(path: url.path))
        let payload = String(repeating: "台灣", count: 500)
        let entries = try (0..<40).map { index in
            String(decoding: try JSONSerialization.data(withJSONObject: ["index": index, "value": payload]), as: UTF8.self) + "\n"
        }
        DispatchQueue.concurrentPerform(iterations: entries.count) { sink.write(entries[$0]) }
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, entries.count)
        XCTAssertEqual(Set(rows.compactMap { $0["index"] as? Int }), Set(0..<40))
        XCTAssertTrue(rows.allSatisfy { $0["value"] as? String == payload })
    }

    func testOpenFailureDoesNotCreateAnOwner() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let closes = Counter()
        XCTAssertNil(DaemonLogFile(path: directory.path, onClose: { closes.hit() }))
        XCTAssertEqual(closes.value, 0)
    }
}
