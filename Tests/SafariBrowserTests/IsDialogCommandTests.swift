import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class IsDialogCommandTests: XCTestCase {
    func testPublicParserAndMCPExposeExplicitDialogQuery() throws {
        XCTAssertNoThrow(try SafariBrowser.parseAsRoot(["is", "dialog"]))
        XCTAssertNoThrow(try SafariBrowser.parseAsRoot(["is", "dialog", "--json"]))
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        XCTAssertTrue(catalog.tools.contains { $0.name == "safari.is.dialog" })
    }
    private func captured(_ body: () throws -> Void) throws -> (String, String, Error?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("stdout")
        let errURL = dir.appendingPathComponent("stderr")
        let out = open(outURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        let err = open(errURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard out >= 0, err >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(out); close(err) }
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO)
        guard savedOut >= 0, savedErr >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(savedOut); close(savedErr) }
        dup2(out, STDOUT_FILENO); dup2(err, STDERR_FILENO)
        var failure: Error?
        do { try body() } catch { failure = error }
        fflush(nil)
        dup2(savedOut, STDOUT_FILENO); dup2(savedErr, STDERR_FILENO)
        return (try String(contentsOf: outURL, encoding: .utf8), try String(contentsOf: errURL, encoding: .utf8), failure)
    }
    func testActualCommandDistinguishesThreeStatesInBothFormats() throws {
        for state in [WindowDialogStatus.State.present, .clear, .unknown] {
            for json in [false, true] {
                let status = WindowDialogStatus(state: state, windowID: 42,
                    messages: state == .present ? ["owned\nmessage"] : [], reason: state == .unknown ? "incomplete" : nil)
                let (out, err, failure) = try captured {
                    try IsDialog.$observation.withValue({ status }) {
                        try IsDialog.parse(json ? ["--json"] : []).run()
                    }
                }
                if json {
                    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
                    XCTAssertEqual(value["state"] as? String, state.rawValue)
                    XCTAssertEqual(value["window_id"] as? Int, 42)
                    XCTAssertEqual(value["messages"] as? [String], status.messages)
                    XCTAssertEqual(Set(value.keys), ["state", "window_id", "messages", "reason"])
                } else {
                    XCTAssertEqual(out, (state == .present ? "true" : state == .clear ? "false" : "unknown") + "\n")
                }
                if state == .unknown {
                    XCTAssertEqual((failure as? ExitCode)?.rawValue, 2)
                    XCTAssertTrue(err.contains("unknown (incomplete)"))
                } else {
                    XCTAssertNil(failure)
                    XCTAssertEqual(err, "")
                }
            }
        }
    }
    func testSelectorsAndTargetsAreRejectedAndLegacyCommandsStillParse() throws {
        for args in [["#field"], ["--window", "1"], ["--url", "example"]] {
            XCTAssertThrowsError(try SafariBrowser.parseAsRoot(["is", "dialog"] + args))
        }
        for verb in ["visible", "exists", "enabled", "checked"] {
            XCTAssertNoThrow(try SafariBrowser.parseAsRoot(["is", verb, "#field"]))
        }
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        let invocation = try catalog.invocation(toolName: "safari.is.dialog", input: .object(["options": .object(["json": .bool(true)])]))
        XCTAssertEqual(invocation.arguments, ["is", "dialog", "--json"])
    }

}
