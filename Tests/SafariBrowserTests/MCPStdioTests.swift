import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class MCPStdioTests: XCTestCase, @unchecked Sendable {
    private final class Pipe: @unchecked Sendable {
        var readFD: Int32
        var writeFD: Int32
        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard Darwin.pipe(&descriptors) == 0 else {
                throw MCPStdioError.systemCall("pipe", errno)
            }
            readFD = descriptors[0]
            writeFD = descriptors[1]
        }
        func put(_ string: String) {
            let bytes = Array(string.utf8)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }, bytes.count)
        }
        func closeWrite() { if writeFD >= 0 { Darwin.close(writeFD); writeFD = -1 } }
        func closeRead() { if readFD >= 0 { Darwin.close(readFD); readFD = -1 } }
        deinit { closeRead(); closeWrite() }
    }

    func testCoalescedFramesAndCleanEOF() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        pipe.put("first\n\nthird\n")
        pipe.closeWrite()
        let first = try await reader.next()
        let second = try await reader.next()
        let third = try await reader.next()
        let eof = try await reader.next()
        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertEqual(second, Data())
        XCTAssertEqual(third, Data("third".utf8))
        XCTAssertNil(eof)
        await reader.close()
    }

    func testSplitFrameAndExactSizeLimit() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD, maximumFrameBytes: 5)
        let reading = Task { try await reader.next() }
        pipe.put("ab")
        await Task.yield()
        pipe.put("cde\n")
        let frame = try await reading.value
        XCTAssertEqual(frame, Data("abcde".utf8))
        await reader.close()
    }

    func testOversizedFrameFailsWithoutWaitingForNewline() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD, maximumFrameBytes: 4)
        pipe.put("12345")
        do { _ = try await reader.next(); XCTFail("accepted oversized frame") }
        catch { XCTAssertEqual(error as? MCPStdioError, .frameTooLarge) }
        await reader.close()
    }

    func testPartialEOFIsAnError() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        pipe.put("{}")
        pipe.closeWrite()
        do { _ = try await reader.next(); XCTFail("accepted frame without newline") }
        catch { XCTAssertEqual(error as? MCPStdioError, .unterminatedFrame) }
        await reader.close()
    }

    func testCancelledReadDoesNotWaitForInput() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let reading = Task { try await reader.next() }
        reading.cancel()
        do { _ = try await reading.value; XCTFail("cancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await reader.close()
    }

    func testWriterAddsOnlyOneDelimiterAndPreservesEscapedNewline() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD)
        let payload = Data(#"{"message":"hello\nthere"}"#.utf8)
        try await writer.write(payload)
        let frame = try await reader.next()
        XCTAssertEqual(frame, payload)
        await writer.close()
        pipe.closeWrite()
        let eof = try await reader.next()
        XCTAssertNil(eof)
        await reader.close()
    }

    func testWriterRejectsOversizeAndLiteralNewlineBeforeWriting() async throws {
        let pipe = try Pipe()
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD, maximumFrameBytes: 4)
        do { try await writer.write(Data("abcde".utf8)); XCTFail("accepted oversized frame") }
        catch { XCTAssertEqual(error as? MCPStdioError, .frameTooLarge) }
        do { try await writer.write(Data("a\nb".utf8)); XCTFail("accepted embedded newline") }
        catch { XCTAssertEqual(error as? MCPStdioError, .embeddedNewline) }
        await writer.close()
    }

    func testBrokenOutputPipeBecomesErrorWithoutSIGPIPE() async throws {
        let pipe = try Pipe()
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD)
        pipe.closeRead()
        do { try await writer.write(Data("{}".utf8)); XCTFail("closed pipe accepted output") }
        catch { XCTAssertEqual(error as? MCPStdioError, .systemCall("write", EPIPE)) }
        await writer.close()
    }

    func testLargeWriteUsesBackpressureAndReaderReassemblesChunks() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD)
        let payload = Data(repeating: 120, count: 512 * 1024)
        let writing = Task { try await writer.write(payload) }
        let frame = try await reader.next()
        try await writing.value
        XCTAssertEqual(frame, payload)
        await writer.close()
        await reader.close()
    }

    func testCancellationStopsWriteBlockedOnBackpressure() async throws {
        let pipe = try Pipe()
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD)
        let writing = Task { try await writer.write(Data(repeating: 120, count: 512 * 1024)) }
        try await Task.sleep(for: .milliseconds(20))
        writing.cancel()
        do { try await writing.value; XCTFail("cancelled write succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await writer.close()
    }

    func testConcurrentWritesNeverInterleaveFrames() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD)
        let first = Data(repeating: 97, count: 128 * 1024)
        let second = Data(repeating: 98, count: 128 * 1024)
        let firstWrite = Task { try await writer.write(first) }
        let secondWrite = Task { try await writer.write(second) }
        let frame1 = try await reader.next()
        let frame2 = try await reader.next()
        try await firstWrite.value
        try await secondWrite.value
        XCTAssertEqual(Set([frame1, frame2]), Set([first, second]))
        await writer.close()
        await reader.close()
    }

    func testConcurrentReadsAreRejectedAndCloseUnblocksOriginalRead() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let firstRead = Task { try await reader.next() }
        try await Task.sleep(for: .milliseconds(20))
        do { _ = try await reader.next(); XCTFail("accepted concurrent reader") }
        catch { XCTAssertEqual(error as? MCPStdioError, .concurrentRead) }
        await reader.close()
        do { _ = try await firstRead.value; XCTFail("closed reader completed normally") }
        catch { XCTAssertEqual(error as? MCPStdioError, .closed) }
    }

    func testOutputQueueHasBoundedAdmissionEvenWhenPipeIsBlocked() async throws {
        let pipe = try Pipe()
        let size = 512 * 1024
        let writer = try MCPStdioWriter(fileDescriptor: pipe.writeFD, maximumFrameBytes: size)
        let payload = Data(repeating: 120, count: size)
        let first = Task { try await writer.write(payload) }
        let second = Task { try await writer.write(payload) }
        try await Task.sleep(for: .milliseconds(20))
        do { try await writer.write(Data("{}".utf8)); XCTFail("unbounded output queue") }
        catch { XCTAssertEqual(error as? MCPStdioError, .writeQueueFull) }
        await writer.close()
        for writing in [first, second] {
            do { try await writing.value; XCTFail("closed writer completed blocked frame") }
            catch { XCTAssertEqual(error as? MCPStdioError, .closed) }
        }
    }

    func testFramingPreservesNonUTF8ForProtocolLayerValidation() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD)
        let raw: [UInt8] = [0xff, 0, 10]
        XCTAssertEqual(raw.withUnsafeBytes { Darwin.write(pipe.writeFD, $0.baseAddress, $0.count) }, raw.count)
        let frame = try await reader.next()
        XCTAssertEqual(frame, Data([0xff, 0]))
        await reader.close()
    }

    func testCoalescedOversizedSecondFrameDoesNotLoseFirstFrame() async throws {
        let pipe = try Pipe()
        let reader = try MCPStdioReader(fileDescriptor: pipe.readFD, maximumFrameBytes: 4)
        pipe.put("ok\n12345\n")
        let first = try await reader.next()
        XCTAssertEqual(first, Data("ok".utf8))
        do { _ = try await reader.next(); XCTFail("oversized second frame accepted") }
        catch { XCTAssertEqual(error as? MCPStdioError, .frameTooLarge) }
        await reader.close()
    }

    func testInvalidDescriptorsAndLimitsFailAtInitialization() throws {
        XCTAssertThrowsError(try MCPStdioReader(fileDescriptor: -1))
        XCTAssertThrowsError(try MCPStdioWriter(fileDescriptor: -1))
        let pipe = try Pipe()
        for limit in [0, -1, Int.max] {
            XCTAssertThrowsError(try MCPStdioReader(fileDescriptor: pipe.readFD, maximumFrameBytes: limit))
            XCTAssertThrowsError(try MCPStdioWriter(fileDescriptor: pipe.writeFD, maximumFrameBytes: limit))
        }
    }
}
