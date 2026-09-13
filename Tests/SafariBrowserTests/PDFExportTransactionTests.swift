import XCTest
import Foundation
import CoreGraphics
import Darwin
import ArgumentParser
@testable import SafariBrowser

@MainActor
final class PDFExportTransactionTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-transaction-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pdf(metadataBytes: Int = 0) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        if metadataBytes > 0 {
            var metadata = Data(count: metadataBytes)
            metadata.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            context.addDocumentMetadata(metadata as CFData)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(rect)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testInvalidDeadlineAndDestinations() throws {
        for timeout in [0, -1, .infinity, .nan] {
            XCTAssertThrowsError(try PDFExportDeadline(timeout: timeout))
        }
        let dir = try folder()
        XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: "bad\0path", overwrite: true))
        XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: dir.path, overwrite: true))
        let link = dir.appendingPathComponent("dir-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: link.path, overwrite: true))
        let fifo = dir.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: fifo.path, overwrite: true))
        XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: dir.appendingPathComponent("absent/file").path, overwrite: true))
    }

    func testMissingAndIncompleteStagingNeverAcceptOldPDF() async throws {
        for bytes in [Data(), Data("%PDF-1.7\ntruncated".utf8), Data("%PDF-1.7\n%%EOF\n".utf8)] {
            let dir = try folder()
            let destination = dir.appendingPathComponent("result.pdf")
            let old = pdf()
            try old.write(to: destination)
            var staging: URL?
            do {
                _ = try await PDFExportTransaction.run(destination: destination, overwrite: true, timeout: 0.15) { url, _ in
                    staging = url
                    if !bytes.isEmpty { try bytes.write(to: url) }
                }
                XCTFail("Missing or incomplete staging must fail")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: destination), old)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging!.deletingLastPathComponent().path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["result.pdf"])
        }
    }

    func testDelayedCompleteFileAndPrivateStaging() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.txt")
        let bytes = pdf()
        var writer: Task<Void, Error>?
        let output = try await PDFExportTransaction.run(destination: destination, overwrite: false, timeout: 2) { staging, _ in
            XCTAssertEqual(staging.pathExtension, "pdf")
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: staging.deletingLastPathComponent().path)
            XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o700)
            writer = Task {
                try Data("%PDF-1.7\n".utf8).write(to: staging)
                try await Task.sleep(for: .milliseconds(100))
                try bytes.write(to: staging)
                XCTAssertEqual(chmod(staging.path, 0o640), 0)
            }
        }
        try await writer?.value
        XCTAssertEqual(output, destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try mode(destination), 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["result.txt"])
    }

    func testPublicationIntermediateRemainsInsidePrivateDirectory() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.pdf")
        let bytes = pdf()
        var writer: Task<Void, Error>?
        _ = try await PDFExportTransaction.run(destination: destination, overwrite: false, timeout: 2) { staging, _ in
            try Data("%PDF-1.7\n".utf8).write(to: staging)
            writer = Task {
                try await Task.sleep(for: .milliseconds(80))
                let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                XCTAssertEqual(items.count, 1)
                let artifact = try XCTUnwrap(items.first)
                let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
                XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o700)
                try bytes.write(to: staging)
            }
        }
        try await writer?.value
    }

    func testLateNoOverwriteCollisionPreservesNewEntry() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.pdf")
        let bytes = pdf()
        do {
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: false) { staging, _ in
                try bytes.write(to: staging)
                try Data("racing writer".utf8).write(to: destination)
            }
            XCTFail("Late collision must fail")
        } catch { XCTAssertTrue(error is ValidationError) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "racing writer")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["result.pdf"])
    }

    func testOverwritePreservesPermissionsAndPublishedInodeIsIndependent() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        XCTAssertEqual(chmod(destination.path, 0o604), 0)
        let bytes = pdf()
        var sourceFD: Int32 = -1
        defer { if sourceFD >= 0 { close(sourceFD) } }
        _ = try await PDFExportTransaction.run(destination: destination, overwrite: true) { staging, _ in
            try bytes.write(to: staging)
            sourceFD = open(staging.path, O_RDWR)
        }
        XCTAssertEqual(try mode(destination), 0o604)
        var sourceInfo = stat(), resultInfo = stat()
        XCTAssertEqual(fstat(sourceFD, &sourceInfo), 0)
        XCTAssertEqual(stat(destination.path, &resultInfo), 0)
        XCTAssertNotEqual(sourceInfo.st_ino, resultInfo.st_ino)
        XCTAssertEqual(ftruncate(sourceFD, 0), 0)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testSymlinkLeafReplacementPreservesReferent() async throws {
        for dangling in [false, true] {
            let dir = try folder()
            let referent = dir.appendingPathComponent("referent")
            if !dangling { try Data("untouched".utf8).write(to: referent) }
            let destination = dir.appendingPathComponent("result.pdf")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: referent)
            XCTAssertThrowsError(try PDFExportTransaction.validateDestination(path: destination.path, overwrite: false))
            let bytes = pdf()
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: true) { staging, _ in
                try bytes.write(to: staging)
            }
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            if dangling { XCTAssertFalse(FileManager.default.fileExists(atPath: referent.path)) }
            else { XCTAssertEqual(try String(contentsOf: referent, encoding: .utf8), "untouched") }
        }
    }

    func testCancellationAndElapsedExporterPreventPublicationAndCleanUp() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.pdf")
        let bytes = pdf()
        var stagingURL: URL?
        let operation = Task {
            try await PDFExportTransaction.run(destination: destination, overwrite: false, timeout: 2) { staging, _ in
                stagingURL = staging
                try bytes.write(to: staging)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await operation.value; XCTFail("Cancelled publication must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL!.deletingLastPathComponent().path))
        do {
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: false, timeout: 0.03) { staging, _ in
                try bytes.write(to: staging)
                try await Task.sleep(for: .milliseconds(60))
            }
            XCTFail("Expired publication must fail")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testSourceMutationOrReplacementDuringCopyRejectsSnapshot() throws {
        let bytes = pdf(metadataBytes: 32 * 1024 * 1024)
        XCTAssertGreaterThan(bytes.count, 32 * 1024 * 1024)
        XCTAssertNotNil(CGPDFDocument(CGDataProvider(data: bytes as CFData)!))
        for replace in [false, true] {
            let dir = try folder()
            let source = dir.appendingPathComponent("source.pdf")
            let other = dir.appendingPathComponent("replacement.pdf")
            let snapshotURL = dir.appendingPathComponent("snapshot.pdf")
            try bytes.write(to: source)
            try bytes.write(to: other)
            let snapshot = open(snapshotURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(snapshot, 0)
            defer { close(snapshot) }
            let result = SnapshotMutationResult()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { finished.signal() }
                let limit = Date().addingTimeInterval(5)
                var info = stat()
                while Date() < limit {
                    if fstat(snapshot, &info) == 0, info.st_size > 0 { break }
                    usleep(100)
                }
                result.observedSize = info.st_size
                if replace {
                    result.result = rename(other.path, source.path)
                } else {
                    let writer = open(source.path, O_WRONLY)
                    defer { close(writer) }
                    // PDF version changes preserve readability, so only coherence rejects this copy.
                    var version: UInt8 = 55
                    result.result = Int32(pwrite(writer, &version, 1, 7)) == 1 ? 0 : -1
                }
            }
            let captured = try PDFExportTransaction.coherentSnapshot(
                source: source, snapshot: snapshot, deadline: PDFExportDeadline(timeout: 5))
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
            XCTAssertEqual(result.result, 0)
            XCTAssertGreaterThan(result.observedSize, 0)
            XCTAssertLessThan(result.observedSize, off_t(bytes.count), "Mutation must occur during the copy")
            XCTAssertNil(captured, "A readable PDF assembled across source generations must be discarded")
            XCTAssertNotNil(try PDFExportTransaction.coherentSnapshot(
                source: source, snapshot: snapshot, deadline: PDFExportDeadline(timeout: 5)))
        }
    }

    func testExporterErrorAndLateDirectoryLeaveDestinationUntouched() async throws {
        let dir = try folder()
        let destination = dir.appendingPathComponent("result.pdf")
        var stagingDirectory: URL?
        do {
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: true) { staging, _ in
                stagingDirectory = staging.deletingLastPathComponent()
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("Exporter error must propagate")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory!.path))
        let bytes = pdf()
        do {
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: true) { staging, _ in
                try bytes.write(to: staging)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            XCTFail("Late directory must not be replaced")
        } catch { XCTAssertTrue(error is ValidationError) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["result.pdf"])
    }

    func testRenamedParentDoesNotRedirectPublication() async throws {
        let root = try folder()
        let parent = root.appendingPathComponent("parent")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("result.pdf")
        let bytes = pdf()
        do {
            _ = try await PDFExportTransaction.run(destination: destination, overwrite: true) { staging, _ in
                try bytes.write(to: staging)
                try FileManager.default.moveItem(at: parent, to: moved)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            }
            XCTFail("A replaced parent path must not report success at the wrong path")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testAtomicNoReplaceRejectsCollisionAtPublicationBoundary() throws {
        let dir = try folder()
        let source = dir.appendingPathComponent("snapshot.pdf")
        let destination = dir.appendingPathComponent("result.pdf")
        let bytes = pdf()
        try bytes.write(to: source)
        let parent = open(dir.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { close(parent) }
        // Represents a writer winning after any earlier destination inspection.
        try Data("late writer".utf8).write(to: destination)
        XCTAssertThrowsError(try PDFExportTransaction.publishSnapshot(
            snapshotDirectory: parent, snapshotName: source.lastPathComponent,
            parent: parent, destinationName: destination.lastPathComponent, overwrite: false)) {
                XCTAssertTrue($0 is ValidationError)
            }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "late writer")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
}

// Values are written by one worker and read only after its semaphore signals completion.
private final class SnapshotMutationResult: @unchecked Sendable {
    var observedSize: off_t = 0
    var result: Int32 = -1
}
