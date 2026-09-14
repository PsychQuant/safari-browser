import Foundation
import XCTest
@testable import SafariBrowser

final class PDFNativeCompletionTests: XCTestCase {
    func testTerminalWaitUsesActualGeneratedControlFlow() async throws {
        // Replace only UI/clock operations, then execute the generated loop.
        for (closeAt, nestedAt, deadline, ownerValid, expected) in [
            (4, 99, 10, true, "done:4"),
            (99, 6, 10, true, "error:6"),
            (99, 99, 3, true, "error:3"),
            (0, 99, 10, false, "error:0")
        ] {
            let body = PdfCommand.completionWaitScript()
                .replacingOccurrences(of: "my verifyPDFOwner(pdfWindowID, pdfPageURL)", with: "if \(ownerValid ? "false" : "true") then error \"owner\"")
                .replacingOccurrences(of: "my checkPDFDeadline(pdfEndTime)", with: "if tick >= \(deadline) then error \"deadline\"")
                .replacingOccurrences(of: "exists sheet 1 of sheet 1 of front window", with: "tick >= \(nestedAt)")
                .replacingOccurrences(of: "exists sheet 1 of front window", with: "tick < \(closeAt)")
                .replacingOccurrences(of: "delay 0.1", with: "set tick to tick + 1")
            XCTAssertFalse(body.contains("click "))
            XCTAssertFalse(body.contains("keystroke"))
            let script = "set tick to 0\ntry\n" + body + "\nreturn \"done:\" & tick\non error\nreturn \"error:\" & tick\nend try"
            let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", script], timeout: 3)
            XCTAssertEqual(result, expected)
        }
    }

    func testPDFNavigationAddsGuardsWithoutChangingUploadDefault() {
        let normal = SafariBridge.fileDialogNavigationScript(path: "/tmp/capture.pdf")
        let pdf = SafariBridge.fileDialogNavigationScript(path: "/tmp/capture.pdf", pdfSave: true)
        XCTAssertFalse(normal.contains("checkPDFDeadline"))
        XCTAssertFalse(normal.contains("expectedSaveFields"))
        XCTAssertTrue(pdf.contains("expectedSaveFields"))
        XCTAssertTrue(pdf.contains("checkPDFDeadline(pdfEndTime)"))
        XCTAssertTrue(pdf.contains("verifyPDFOwner(pdfWindowID, pdfPageURL)"))
        XCTAssertEqual(pdf.components(separatedBy: "click defaultBtn").count - 1, 1)
    }

    func testStagingScriptHasNoReplacementShortcutAndCompiles() async throws {
        let script = PdfCommand.exportScript(path: "/tmp/capture.pdf", windowIndex: 1, timeout: 60)
        XCTAssertTrue(script.contains("set pdfEndTime"))
        XCTAssertTrue(script.contains(PdfCommand.completionWaitScript()))
        XCTAssertFalse(script.contains("click replaceBtn"))
        XCTAssertFalse(script.contains("delay 0.5\n        if exists sheet"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("script.applescript")
        try script.write(to: source, atomically: true, encoding: .utf8)
        _ = try await SafariBridge.runShell("/usr/bin/osacompile", ["-o", dir.appendingPathComponent("script.scpt").path, source.path], timeout: 5)
    }
}
