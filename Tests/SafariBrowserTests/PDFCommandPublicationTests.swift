import ArgumentParser
import CoreGraphics
import Foundation
import XCTest
@testable import SafariBrowser

final class PDFCommandPublicationTests: XCTestCase {
    static func writePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
    }

    func testNativeBoundaryReceivesPrivatePDFAndPublishesEffectivePath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["no-extension", "explicit.txt", "normal.pdf"] {
            let requested = dir.appendingPathComponent(name)
            let expected = name == "no-extension" ? requested.appendingPathExtension("pdf") : requested
            let calls = ExecSubprocessOutputTests.Output()
            try await PdfCommand.$nativeExporter.withValue({ staging in
                calls.append(staging)
                XCTAssertNotEqual(staging, expected.path)
                XCTAssertTrue(staging.hasSuffix(".pdf"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
                try Self.writePDF(to: URL(fileURLWithPath: staging))
            }) {
                try await PdfCommand.parse(["--allow-hid", requested.path]).run()
            }
            XCTAssertFalse(calls.text.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls.text))
            let pdf = try XCTUnwrap(CGPDFDocument(expected as CFURL))
            XCTAssertEqual(pdf.numberOfPages, 1)
            if name == "no-extension" { XCTAssertFalse(FileManager.default.fileExists(atPath: requested.path)) }
        }
    }

    func testNativeFailurePreservesOriginalAndCleansStaging() async throws {
        enum Sentinel: Error { case nativeFailure }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("ORIGINAL".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = ExecSubprocessOutputTests.Output()
        do {
            try await PdfCommand.$nativeExporter.withValue({ staging in
                calls.append(staging)
                try Self.writePDF(to: URL(fileURLWithPath: staging))
                throw Sentinel.nativeFailure
            }) {
                try await PdfCommand.parse(["--allow-hid", "--overwrite", file.path]).run()
            }
            XCTFail("Native failure must propagate even when a valid PDF exists")
        } catch Sentinel.nativeFailure { }
        XCTAssertEqual(try Data(contentsOf: file), Data("ORIGINAL".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.text))
    }

    func testEffectivePathValidationRunsBeforeNativeBoundary() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("original".utf8).write(to: dir.appendingPathComponent("name.pdf"))
        do {
            try await PdfCommand.$nativeExporter.withValue({ _ in XCTFail("preflight must precede exporter") }) {
                try await PdfCommand.parse(["--allow-hid", dir.appendingPathComponent("name").path]).run()
            }
            XCTFail("effective .pdf already exists")
        } catch is ValidationError { }
    }
}
