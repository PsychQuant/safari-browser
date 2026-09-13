import ArgumentParser
import Foundation

struct IsDialog: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dialog",
        abstract: "Check the selected tab's native dialog in Safari's main window (true/false/unknown)"
    )
    @Flag(name: .long, help: "Output state, window ID, messages and reason as JSON")
    var json = false

    /// Tests replace the observation boundary; output and exit behavior stay real.
    @TaskLocal static var observation: (@Sendable () -> WindowDialogStatus)?

    func run() throws {
        let status = Self.observation?() ?? CurrentWindowDialogProbe.shared.observe()
        if json {
            let data = try JSONSerialization.data(withJSONObject: status.jsonObject, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            switch status.state {
            case .present: print("true")
            case .clear: print("false")
            case .unknown: print("unknown")
            }
        }
        if status.state == .unknown {
            let reason = TerminalText.escaped(status.reason ?? "incomplete", limit: 160)
            FileHandle.standardError.write(Data("Native dialog state is unknown (\(reason)); inspect Safari before relying on this result.\n".utf8))
            throw ExitCode(2)
        }
    }
}
