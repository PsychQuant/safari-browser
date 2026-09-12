import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class FileDialogConfirmationPolicyTests: XCTestCase {
    func testOverwriteFlagIsExplicit() throws {
        XCTAssertNoThrow(try PdfCommand.parse(["--allow-hid", "--overwrite", "out.pdf"]))
    }

    func testExistingDestinationFailsBeforeNativeExporter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("existing.pdf")
        try Data("original".utf8).write(to: file)
        let calls = ExecSubprocessOutputTests.Output()
        let command = try PdfCommand.parse(["--allow-hid", file.path])
        do {
            try await PdfCommand.$nativeExporter.withValue({ _ in calls.append("export") }) {
                try await command.run()
            }
            XCTFail("existing output must require explicit overwrite")
        } catch let error as ValidationError {
            XCTAssertTrue(String(describing: error).contains("--overwrite"))
        }
        XCTAssertEqual(calls.text, "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testInitialConfirmationDoesNotRetryAnAttemptedClick() {
        let script = SafariBridge.fileDialogNavigationScript(path: "/tmp/fixture.pdf")
        let attempted = script.range(of: "set confirmationAttempted to true")
        let click = script.range(of: "click defaultBtn")
        let refuse = script.range(of: "if confirmationAttempted then error")
        XCTAssertNotNil(attempted)
        XCTAssertNotNil(click)
        XCTAssertNotNil(refuse)
        if let attempted, let click { XCTAssertLessThan(attempted.lowerBound, click.lowerBound) }
        if let click, let refuse { XCTAssertLessThan(click.lowerBound, refuse.lowerBound) }
    }

    func testDefaultExportRefusesLateReplacementInsteadOfConfirmingIt() {
        let script = PdfCommand.exportScript(path: "/tmp/fixture.pdf", windowIndex: 1)
        let replacement = script.components(separatedBy: "-- Replacement confirmation").last ?? script
        XCTAssertTrue(replacement.contains("requires --overwrite"))
        XCTAssertFalse(replacement.contains("click replaceBtn"))
        XCTAssertFalse(replacement.contains("keystroke return"))
    }

    func testAuthorizedOverwriteReachesExporterButNeverDropsHIDRequirement() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("original".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = ExecSubprocessOutputTests.Output()
        try await PdfCommand.$nativeExporter.withValue({ path in calls.append(path) }) {
            try await PdfCommand.parse(["--allow-hid", "--overwrite", file.path]).run()
        }
        XCTAssertEqual(calls.text, file.path)
        do {
            try await PdfCommand.$nativeExporter.withValue({ _ in XCTFail("missing HID authorization") }) {
                try await PdfCommand.parse(["--overwrite", file.path]).run()
            }
            XCTFail("overwrite must not authorize keyboard control")
        } catch { XCTAssertTrue(String(describing: error).contains("--allow-hid")) }
    }

    func testPreflightCountsDanglingLinkAsExistingAndRejectsDirectoryOrNUL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("dangling.pdf")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: directory.appendingPathComponent("missing.pdf").path)
        XCTAssertThrowsError(try PdfCommand.validateDestination(link.path, overwrite: false))
        XCTAssertThrowsError(try PdfCommand.validateDestination(directory.path, overwrite: true))
        XCTAssertThrowsError(try PdfCommand.validateDestination("/tmp/a\0b", overwrite: true))
        XCTAssertNoThrow(try PdfCommand.validateDestination(directory.appendingPathComponent("new.pdf").path, overwrite: false))
    }

    func testGeneratedConfirmationControlFlowWithSyntheticOperations() async throws {
        // Execute the actual generated control flow, replacing only external
        // UI operations with pure AppleScript effects. Never address Safari.
        for (lookupFails, pressFails, lostFocus, nested, expected) in [
            (false, false, false, false, "true,false,false"),
            (false, true, false, false, "true,false,true"),
            (true, false, false, false, "false,true,false"),
            (true, false, true, false, "false,false,true"),
            (true, false, false, true, "false,false,true")
        ] {
            let lines = SafariBridge.fileDialogConfirmationScript().components(separatedBy: "\n").map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("set defaultBtn to") { return lookupFails ? "error \"lookup\" number 7001" : "set defaultBtn to \"Open\"" }
                if trimmed.hasPrefix("set defaultTitle to") { return "set defaultTitle to defaultBtn" }
                if trimmed == "click defaultBtn" { return "set didPress to true" + (pressFails ? "\nerror \"uncertain\" number 7002" : "") }
                if trimmed == "keystroke return" { return "set didReturn to true" }
                if trimmed.hasPrefix("if not frontmost then") { return "if \(lostFocus ? "true" : "false") then error \"focus\"" }
                if trimmed.hasPrefix("if not (exists sheet") { return "if false then error \"missing sheet\"" }
                if trimmed.hasPrefix("if exists sheet") { return "if \(nested ? "true" : "false") then error \"nested\"" }
                return line
            }
            let body = lines.joined(separator: "\n")
            XCTAssertFalse(body.contains("AXDefault"))
            XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("click ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("keystroke ") })
            let script = "set didPress to false\nset didReturn to false\nset caught to false\ntry\n" + body
                + "\non error\nset caught to true\nend try\nreturn (didPress as text) & \",\" & (didReturn as text) & \",\" & (caught as text)"
            let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", script], timeout: 3)
            XCTAssertEqual(result, expected)
        }
    }

    func testProductionFileDialogScriptsCompileWithoutRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scripts = [PdfCommand.exportScript(path: "/tmp/fixture.pdf", windowIndex: 1),
                       PdfCommand.exportScript(path: "/tmp/fixture.pdf", windowIndex: 1, overwrite: true),
                       UploadCommand.nativeDialogScript(path: "/tmp/fixture.txt", window: 1),
                       SafariBridge.fileDialogNavigationOuterScript(path: "/tmp/fixture.txt")]
        for (index, script) in scripts.enumerated() {
            let source = directory.appendingPathComponent("\(index).applescript")
            try script.write(to: source, atomically: true, encoding: .utf8)
            _ = try await SafariBridge.runShell("/usr/bin/osacompile", ["-o", directory.appendingPathComponent("\(index).scpt").path, source.path], timeout: 5)
        }
    }
}
