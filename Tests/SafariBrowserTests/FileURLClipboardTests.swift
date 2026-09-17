import AppKit
import XCTest
@testable import SafariBrowser

@MainActor
final class FileURLClipboardTests: XCTestCase {
    private func withBoard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard(name: .init("file-url-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try body(board)
    }

    private let url = URL(fileURLWithPath: "/tmp/.隱藏 資料/it's a file.txt")

    private func seed(_ board: NSPasteboard) {
        let one = NSPasteboardItem(), two = NSPasteboardItem()
        XCTAssertTrue(one.setData(Data([0, 255, 1, 0]), forType: .init("test.opaque")))
        XCTAssertTrue(one.setString("第一筆", forType: .string))
        XCTAssertTrue(two.setString("second", forType: .string))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([one, two]))
    }

    private func contents(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, item.data(forType: $0)!) })
        }
    }

    func testFileURLAndMultipleItemTypesRestoreExactly() throws {
        try withBoard { board in
            seed(board)
            let before = contents(board)
            let beforeTypes = board.pasteboardItems!.map(\.types)
            let lease = try FileURLClipboard(fileURL: url, pasteboard: board)
            XCTAssertEqual(board.changeCount, lease.ownedChangeCount)
            let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
            XCTAssertEqual(urls, [url])
            XCTAssertEqual(try lease.restore(), .restored)
            XCTAssertEqual(contents(board), before)
            XCTAssertEqual(board.pasteboardItems!.map(\.types), beforeTypes)
            let restoredCount = board.changeCount
            XCTAssertEqual(try lease.restore(), .restored)
            XCTAssertEqual(board.changeCount, restoredCount)
        }
    }

    func testEmptySnapshotAndZeroBudget() throws {
        try withBoard { board in
            board.clearContents()
            let lease = try FileURLClipboard(fileURL: url, pasteboard: board, maximumBytes: 0)
            XCTAssertEqual(try lease.restore(), .restored)
            XCTAssertTrue(contents(board).isEmpty)
        }
    }

    func testOversizedAndInvalidInputsDoNotMutate() throws {
        try withBoard { board in
            seed(board)
            let before = contents(board), count = board.changeCount
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, pasteboard: board, maximumBytes: 1))
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, pasteboard: board, maximumBytes: -1))
            XCTAssertThrowsError(try FileURLClipboard(fileURL: URL(string: "https://example.com")!, pasteboard: board))
            XCTAssertEqual(contents(board), before)
            XCTAssertEqual(board.changeCount, count)
        }
    }

    func testNewerContentsPreservedIncludingRepeatedRestore() throws {
        try withBoard { board in
            seed(board)
            let lease = try FileURLClipboard(fileURL: url, pasteboard: board)
            board.clearContents()
            board.setString("new user copy", forType: .string)
            let count = board.changeCount
            XCTAssertEqual(try lease.restore(), .preservedNewer)
            XCTAssertEqual(try lease.restore(), .preservedNewer)
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(board.string(forType: .string), "new user copy")
        }
    }

    func testUnreadableRepresentationRefusesBeforeMutation() throws {
        try withBoard { board in
            seed(board)
            let count = board.changeCount, before = contents(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.readItems = { [[.init(type: .string, data: { nil })]] }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(contents(board), before)
        }
    }

    func testChangeDuringSnapshotPreservesNewerContent() throws {
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.readItems = {
                [[.init(type: .string, data: {
                    board.clearContents()
                    board.setString("concurrent snapshot copy", forType: .string)
                    return Data("old bytes".utf8)
                })]]
            }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            XCTAssertEqual(board.string(forType: .string), "concurrent snapshot copy")
        }
    }

    func testFailedFileURLWriteRestoresOriginal() throws {
        try withBoard { board in
            seed(board)
            let before = contents(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.writeFileURL = { _ in false }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations)) { error in
                XCTAssertTrue(error.localizedDescription.contains("restored"))
            }
            XCTAssertEqual(contents(board), before)
        }
    }

    func testFailedFileURLWritePreservesDetectedConcurrentCopy() throws {
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.writeFileURL = { _ in
                board.clearContents()
                board.setString("concurrent writer", forType: .string)
                return false
            }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            XCTAssertEqual(board.string(forType: .string), "concurrent writer")
        }
    }

    func testRestorationFailureIsExplicit() throws {
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.writeItems = { _ in false }
            let lease = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertThrowsError(try lease.restore())
            XCTAssertThrowsError(try lease.restore(), "A failed restore must not later appear successful")
        }
    }

    func testBudgetCountsAllRepresentationsAndItems() throws {
        try withBoard { board in
            seed(board)
            let before = contents(board), count = board.changeCount
            let size = before.flatMap { $0.values }.reduce(0) { $0 + $1.count }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, pasteboard: board, maximumBytes: size - 1))
            XCTAssertEqual(board.changeCount, count)
            let lease = try FileURLClipboard(fileURL: url, pasteboard: board, maximumBytes: size)
            XCTAssertEqual(try lease.restore(), .restored)
            XCTAssertEqual(contents(board), before)
        }
    }

    func testNewerCopyDuringRestoreClearIsNotOverwritten() throws {
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            var clears = 0
            operations.clear = {
                clears += 1
                let ownedCount = board.clearContents()
                if clears == 2 {
                    board.clearContents()
                    board.setString("copy during restore", forType: .string)
                }
                return ownedCount
            }
            let lease = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertEqual(try lease.restore(), .preservedNewer)
            XCTAssertEqual(board.string(forType: .string), "copy during restore")
        }
    }

    func testWriteAndRollbackFailureAreBothReported() throws {
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.writeFileURL = { _ in false }
            operations.writeItems = { _ in false }
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations)) { error in
                XCTAssertTrue(error.localizedDescription.contains("restoration failed"))
            }
        }
    }

    func testOverlappingLeaseRejectedBeforeMutation() throws {
        try withBoard { board in
            seed(board)
            let original = contents(board)
            let first = try FileURLClipboard(fileURL: url, pasteboard: board)
            let firstCount = board.changeCount
            var second: FileURLClipboard?
            XCTAssertThrowsError(second = try FileURLClipboard(fileURL: URL(fileURLWithPath: "/tmp/second"), pasteboard: board))
            XCTAssertThrowsError(second = try FileURLClipboard(fileURL: URL(fileURLWithPath: "/tmp/third"), pasteboard: board), "A rejected lease must not release the first owner's registry entry")
            XCTAssertEqual(board.changeCount, firstCount)
            XCTAssertEqual(try first.restore(), .restored)
            // Cleanup also demonstrates how an accepted overlap loses the
            // original clipboard by restoring the first temporary file URL.
            _ = try second?.restore()
            XCTAssertEqual(contents(board), original)
        }
    }

    private func privateLockDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testGeneralLockUsesOSUserNamespaceInsteadOfSharedTmp() throws {
        let osDirectory = try FileURLClipboard.darwinUserTemporaryDirectory()
        let directory = try XCTUnwrap(FileURLClipboard.lockDirectory(for: .general))
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, osDirectory.standardizedFileURL)
        XCTAssertEqual(directory.lastPathComponent, "safari-browser-native-upload")
        XCTAssertEqual(try FileURLClipboard.lockDirectory(for: .general), directory)
        let fixtureDirectory = try privateLockDirectory()
        let chosen = try XCTUnwrap(FileURLClipboard.lockDirectory(for: .general, userTemporaryDirectory: { fixtureDirectory }))
        XCTAssertEqual(chosen.deletingLastPathComponent().path, fixtureDirectory.path)
    }

    func testNamespaceResolutionFailureCannotSilentlySkipLock() throws {
        enum Failure: Error { case unavailable }
        try withBoard { board in
            seed(board)
            let count = board.changeCount, original = contents(board)
            XCTAssertThrowsError(try {
                var operations = try FileURLClipboard.Operations(pasteboard: board)
                operations.lockDirectory = try FileURLClipboard.lockDirectory(for: .general, userTemporaryDirectory: { throw Failure.unavailable })
                let lease = try FileURLClipboard(fileURL: url, operations: operations)
                _ = try lease.restore()
            }())
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(contents(board), original)
            XCTAssertNil(try FileURLClipboard.lockDirectory(for: board.name, userTemporaryDirectory: { throw Failure.unavailable }))
        }
    }

    func testPrivateAdvisoryLockContentionAndReacquisition() throws {
        let directory = try privateLockDirectory()
        try withBoard { board in
            seed(board)
            let before = contents(board), count = board.changeCount
            let lockPath = directory.appendingPathComponent("clipboard.lock").path
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import os,fcntl,sys,select; f=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(f,fcntl.LOCK_EX); print('READY',flush=True); select.select([sys.stdin],[],[],15); os.close(f)", lockPath]
            process.standardOutput = output
            process.standardInput = input
            try process.run()
            defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
            XCTAssertEqual(String(data: output.fileHandleForReading.readData(ofLength: 6), encoding: .utf8), "READY\n")
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.lockDirectory = directory
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(contents(board), before)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let lease = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertEqual(try lease.restore(), .restored)
            let next = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertEqual(try next.restore(), .restored)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "Lock pathname must remain stable")
            XCTAssertEqual(contents(board), before)
        }
    }

    func testUnsafeLockFileAndDirectoryRefuseBeforeClipboardMutation() throws {
        let directory = try privateLockDirectory()
        let file = directory.appendingPathComponent("clipboard.lock")
        try withBoard { board in
            seed(board)
            let before = contents(board), count = board.changeCount
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.lockDirectory = directory
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent-target"))
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations))
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(contents(board), before)
        }
    }

    func testRegistryAndLockReleasedOnEveryLifecycleExit() throws {
        let directory = try privateLockDirectory()
        try withBoard { board in
            seed(board)
            var operations = try FileURLClipboard.Operations(pasteboard: board)
            operations.lockDirectory = directory
            XCTAssertThrowsError(try FileURLClipboard(fileURL: url, operations: operations, maximumBytes: 0))
            var abandoned: FileURLClipboard? = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertNotNil(abandoned)
            let abandonedCount = board.changeCount
            abandoned = nil
            XCTAssertEqual(board.changeCount, abandonedCount, "Deinit must not change clipboard contents")
            let next = try FileURLClipboard(fileURL: url, operations: operations)
            board.clearContents()
            board.setString("newer", forType: .string)
            XCTAssertEqual(try next.restore(), .preservedNewer)
            var failing = operations
            failing.writeItems = { _ in false }
            let failedRestore = try FileURLClipboard(fileURL: url, operations: failing)
            XCTAssertThrowsError(try failedRestore.restore())
            let final = try FileURLClipboard(fileURL: url, operations: operations)
            XCTAssertEqual(try final.restore(), .restored)
        }
    }
}
