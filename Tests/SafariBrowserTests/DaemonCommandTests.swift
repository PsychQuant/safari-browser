import XCTest
import ArgumentParser
@testable import SafariBrowser

/// Smoke tests for DaemonCommand parsing. Phase 1 scaffold only —
/// these assert the subcommand tree parses correctly, not that the
/// daemon actually runs. Actual daemon behaviour tests live in
/// DaemonServerTests, DaemonClientTests, etc.
final class DaemonCommandTests: XCTestCase {

    func testDaemonCommand_hasExpectedSubcommands() {
        let subcommands = DaemonCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertTrue(subcommands.contains("DaemonStartCommand"))
        XCTAssertTrue(subcommands.contains("DaemonStopCommand"))
        XCTAssertTrue(subcommands.contains("DaemonStatusCommand"))
        XCTAssertTrue(subcommands.contains("DaemonLogsCommand"))
    }

    func testDaemonStartCommand_parses() throws {
        let command = try DaemonStartCommand.parse([])
        XCTAssertNotNil(command)
    }

    func testDaemonStopCommand_parses() throws {
        let command = try DaemonStopCommand.parse([])
        XCTAssertNotNil(command)
    }

    func testDaemonStatusCommand_parses() throws {
        let command = try DaemonStatusCommand.parse([])
        XCTAssertNotNil(command)
    }

    func testDaemonLogsCommand_parses() throws {
        let command = try DaemonLogsCommand.parse([])
        XCTAssertNotNil(command)
    }

    // --name flag should be accepted on all daemon subcommands so a user can
    // operate on non-default namespaces. NAME resolution logic (precedence,
    // env fallback) is validated in DaemonNameResolverTests once that path
    // lands in task 2.2.
    func testDaemonStart_acceptsNameFlag() throws {
        let command = try DaemonStartCommand.parse(["--name", "alpha"])
        XCTAssertEqual(command.name, "alpha")
    }

    func testDaemonStatus_acceptsNameFlag() throws {
        let command = try DaemonStatusCommand.parse(["--name", "beta"])
        XCTAssertEqual(command.name, "beta")
    }
}
