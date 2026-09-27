import XCTest
import Foundation
import Darwin
@testable import SafariBrowser

final class DaemonPidOwnershipTests: XCTestCase {
    private let record = DaemonPaths.PidRecord(pid: 4242, exec: "/fixture/safari-browser", boot: 1_700_000_000.5)

    private func withFixture(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-pid-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.path)
    }

    func testCleanupRemovesSameEntry() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)

            XCTAssertTrue(identity.removeIfMatches(at: path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(identity.removeIfMatches(at: path))
        }
    }

    func testCleanupRetainsReplacementWithIdenticalRecord() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let previousPath = directory + "/previous.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try FileManager.default.moveItem(atPath: path, toPath: previousPath)
            // 保留原 inode，避免測試受到 inode 回收重用影響。
            try originalBytes.write(to: URL(fileURLWithPath: path))

            XCTAssertFalse(identity.removeIfMatches(at: path))
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), originalBytes)
            XCTAssertTrue(identity.removeIfMatches(at: previousPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: previousPath))
        }
    }

    func testCleanupRetainsSymlinkEvenWhenTargetIsOwnedEntry() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let target = directory + "/previous.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try FileManager.default.moveItem(atPath: path, toPath: target)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

            XCTAssertFalse(identity.removeIfMatches(at: path))
            XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: path), target)
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: target)), originalBytes)
        }
    }

    func testCleanupOfAbsentPathLeavesOwnedEntryUntouched() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)

            XCTAssertFalse(identity.removeIfMatches(at: directory + "/absent.pid"))
            XCTAssertEqual(DaemonPaths.readPidFile(at: path), .ok(record))
        }
    }

    func testUnconfirmablePathIsRetained() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)
            let loop = directory + "/loop"
            try FileManager.default.createSymbolicLink(atPath: loop, withDestinationPath: loop)

            // 自循環父連結使 lstat 回傳 ELOOP，且不需調整程序權限。
            XCTAssertFalse(identity.removeIfMatches(at: loop + "/daemon.pid"))
            XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: loop), loop)
            XCTAssertEqual(DaemonPaths.readPidFile(at: path), .ok(record))
        }
    }

    func testIdentityUsesOpenDescriptorAfterPathReplacement() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let previousPath = directory + "/previous.pid"
            let writtenIdentity = try DaemonPaths.writePidFile(record: record, at: path)
            let fd = Darwin.open(path, O_RDONLY)
            guard fd >= 0 else { return XCTFail("fixture open failed: \(errno)") }
            defer { Darwin.close(fd) }
            try FileManager.default.moveItem(atPath: path, toPath: previousPath)
            let replacementIdentity = try DaemonPaths.writePidFile(record: record, at: path)

            let descriptorIdentity = try DaemonPaths.EntryIdentity(fd: fd)
            XCTAssertEqual(descriptorIdentity, writtenIdentity)
            XCTAssertNotEqual(descriptorIdentity, replacementIdentity)
            XCTAssertFalse(descriptorIdentity.removeIfMatches(at: path))
            XCTAssertTrue(descriptorIdentity.removeIfMatches(at: previousPath))
            XCTAssertEqual(DaemonPaths.readPidFile(at: path), .ok(record))
        }
    }

    func testInvalidDescriptorCannotProduceIdentity() {
        XCTAssertThrowsError(try DaemonPaths.EntryIdentity(fd: -1))
    }

    func testJSONPayloadPermissionsAndExclusiveCreateArePreserved() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let identity = try DaemonPaths.writePidFile(record: record, at: path)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(bytes.last, 0x0A)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(json.keys), ["pid", "exec", "boot"])
            XCTAssertEqual(json["pid"] as? Int, 4242)
            XCTAssertEqual(json["exec"] as? String, "/fixture/safari-browser")
            XCTAssertEqual(json["boot"] as? Double, 1_700_000_000.5)
            var info = Darwin.stat()
            XCTAssertEqual(lstat(path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)

            let otherRecord = DaemonPaths.PidRecord(pid: 9999, exec: "/other", boot: 0)
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: otherRecord, at: path)) { error in
                guard case DaemonPaths.PidWriteError.openFailed(let code, _) = error else {
                    return XCTFail("expected exclusive-create error, got \(error)")
                }
                XCTAssertEqual(code, EEXIST)
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            XCTAssertTrue(identity.removeIfMatches(at: path))
        }
    }

    func testFailedWriteRemovesOwnedEntryAndPreservesOriginalError() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, writeF: { _, _, _ in
                errno = ENOSPC
                return -1
            })) { error in
                guard case DaemonPaths.PidWriteError.writeFailed(let code, let written, _) = error else {
                    return XCTFail("expected write failure, got \(error)")
                }
                XCTAssertEqual(code, ENOSPC)
                XCTAssertEqual(written, -1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testShortWriteRemovesOwnedPartialEntry() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, writeF: { fd, bytes, count in
                Darwin.write(fd, bytes, count - 1)
            })) { error in
                guard case DaemonPaths.PidWriteError.writeFailed(_, let written, let expected) = error else {
                    return XCTFail("expected short write, got \(error)")
                }
                XCTAssertEqual(written, expected - 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testFailedWriteRetainsReplacement() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let previousPath = directory + "/previous.pid"
            let replacement = Data("replacement belongs to another run".utf8)
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, writeF: { _, _, _ in
                XCTAssertEqual(Darwin.rename(path, previousPath), 0)
                do {
                    try replacement.write(to: URL(fileURLWithPath: path))
                } catch {
                    XCTFail("fixture replacement failed: \(error)")
                }
                errno = ENOSPC
                return -1
            })) { error in
                guard case DaemonPaths.PidWriteError.writeFailed(let code, _, _) = error else {
                    return XCTFail("expected write failure, got \(error)")
                }
                XCTAssertEqual(code, ENOSPC)
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: previousPath))
        }
    }

    private func descriptorsHolding(_ entry: Darwin.stat) throws -> [Int32] {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
            .compactMap(Int32.init)
            .filter { fd in
                var current = Darwin.stat()
                return Darwin.fstat(fd, &current) == 0 &&
                    current.st_dev == entry.st_dev && current.st_ino == entry.st_ino
            }
    }

    func testIdentityPinsUnlinkedInodeUntilLastCopyIsReleased() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            var identity: DaemonPaths.EntryIdentity? = try DaemonPaths.writePidFile(record: record, at: path)
            var info = Darwin.stat()
            XCTAssertEqual(lstat(path, &info), 0)
            let descriptors = try withExtendedLifetime(identity) { try descriptorsHolding(info) }
            XCTAssertEqual(descriptors.count, 1, "identity must retain one owned descriptor")
            for fd in descriptors {
                XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
            }
            var survivingCopy = identity
            identity = nil
            XCTAssertEqual(Darwin.unlink(path), 0)
            let replacement = try DaemonPaths.writePidFile(record: record, at: path)
            XCTAssertNotEqual(survivingCopy, replacement)
            XCTAssertFalse(try XCTUnwrap(survivingCopy).removeIfMatches(at: path))
            try withExtendedLifetime(survivingCopy) {
                XCTAssertEqual(try descriptorsHolding(info), descriptors)
            }
            survivingCopy = nil
            XCTAssertEqual(try descriptorsHolding(info), [])
            XCTAssertEqual(DaemonPaths.readPidFile(at: path), .ok(record))
            withExtendedLifetime(replacement) {}
        }
    }


    func testFailedDupRemovesConfirmedEntryAndClosesOriginalDescriptor() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            var originalFD: Int32 = -1
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, duplicateF: { fd in
                originalFD = fd
                errno = EMFILE
                return -1
            })) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EMFILE)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertGreaterThanOrEqual(originalFD, 0)
            XCTAssertEqual(fcntl(originalFD, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testFailedDupRetainsReplacementEntry() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let replacement = Data("replacement belongs to another run".utf8)
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, duplicateF: { _ in
                XCTAssertEqual(Darwin.unlink(path), 0)
                do {
                    try replacement.write(to: URL(fileURLWithPath: path))
                } catch {
                    XCTFail("fixture replacement failed: \(error)")
                }
                errno = EMFILE
                return -1
            })) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EMFILE)
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        }
    }

    func testFailedStatRetainsUnconfirmedEntryAndClosesDescriptor() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            var originalFD: Int32 = -1
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, statF: { fd, _ in
                originalFD = fd
                errno = EIO
                return -1
            })) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EIO)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertGreaterThanOrEqual(originalFD, 0)
            XCTAssertEqual(fcntl(originalFD, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testFailedStatRetainsReplacementEntry() throws {
        try withFixture { directory in
            let path = directory + "/daemon.pid"
            let replacement = Data("replacement belongs to another run".utf8)
            XCTAssertThrowsError(try DaemonPaths.writePidFile(record: record, at: path, statF: { _, _ in
                XCTAssertEqual(Darwin.unlink(path), 0)
                do {
                    try replacement.write(to: URL(fileURLWithPath: path))
                } catch {
                    XCTFail("fixture replacement failed: \(error)")
                }
                errno = EIO
                return -1
            })) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EIO)
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        }
    }

}
