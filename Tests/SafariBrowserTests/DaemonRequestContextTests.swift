import XCTest
import Foundation
@testable import SafariBrowser

final class DaemonRequestContextTests: XCTestCase {
    func testRegisteredHandlersReceiveDifferentRequestContexts() async throws {
        let name = "ctx-\(UUID().uuidString.prefix(8))"
        let server = DaemonServer.Instance()
        await server.register("context") { _ in
            guard let context = DaemonRequestContext.current else {
                return Data(#"{"context":"missing"}"#.utf8)
            }
            context.emit("request warning\n")
            return try JSONSerialization.data(withJSONObject: ["context": context.id.uuidString])
        }
        try await server.start(socketPath: DaemonClient.socketPath(name: name))
        defer { Task { await server.stop() } }
        var ids = Set<String>()
        for request in 1...2 {
            let data = try await DaemonClient.sendRequest(name: name, method: "context",
                params: Data("{}".utf8), requestId: request)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertNotEqual(result["context"], "missing")
            ids.insert(try XCTUnwrap(result["context"]))
        }
        XCTAssertEqual(ids.count, 2)
    }

    func testInjectedExecutorIsUsedInsteadOfDaemonSocket() async throws {
        let context = DaemonRequestContext()
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "42" }) {
                try await SafariBridge.runAppleScript("return 7")
            }
        }
        XCTAssertEqual(result, "42")
    }
    func testMalformedExecResultCannotTriggerLocalReplay() {
        for data in [Data("{}".utf8), Data(#"{"results":7}"#.utf8)] {
            XCTAssertThrowsError(try ExecCommand.daemonResults(from: data))
        }
    }

    func testInterleavedGateWarningsStayWithTheirRequest() async throws {
        let contexts = ["alpha", "beta"].map { message in
            DaemonRequestContext(probe: { _ in
                .present(SafariBridge.BlockingDialog(message: message, buttons: ["OK"]))
            })
        }
        await withTaskGroup(of: Void.self) { group in
            for context in contexts {
                group.addTask {
                    await DaemonRequestContext.$current.withValue(context) {
                        BlockingDialogGate.shared.check(.id(1))
                        await Task.yield()
                        BlockingDialogGate.shared.check(.id(1))
                    }
                }
            }
        }
        for (index, name) in ["alpha", "beta"].enumerated() {
            XCTAssertEqual(contexts[index].diagnostics.count, 1)
            XCTAssertTrue(contexts[index].diagnostics[0].contains(name))
            XCTAssertFalse(contexts[index].diagnostics[0].contains(index == 0 ? "beta" : "alpha"))
        }
        XCTAssertNil(DaemonRequestContext.current)
    }

    func testServerForwardsWarningsForSuccessAndFailure() async throws {
        let name = "warnings-\(UUID().uuidString.prefix(8))"
        let server = DaemonServer.Instance()
        await server.register("ok") { _ in
            DaemonRequestContext.current?.emit("success warning\n")
            return Data("{}".utf8)
        }
        await server.register("fail") { _ in
            DaemonRequestContext.current?.emit("failure warning\n")
            throw NSError(domain: "test", code: 7)
        }
        try await server.start(socketPath: DaemonClient.socketPath(name: name))
        defer { Task { await server.stop() } }
        for method in ["ok", "fail", "ok"] {
            let output = ExecSubprocessOutputTests.Output()
            do {
                _ = try await DaemonClient.sendRequest(name: name, method: method,
                    params: Data("{}".utf8), requestId: 1,
                    diagnosticsWriter: { output.append($0) })
                XCTAssertEqual(method, "ok")
            } catch {
                XCTAssertEqual(method, "fail")
            }
            XCTAssertEqual(output.text, method == "ok" ? "success warning\n" : "failure warning\n")
        }
    }

}
