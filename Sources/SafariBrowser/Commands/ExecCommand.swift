import ArgumentParser
import Foundation

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Execute a JSON script of safari-browser steps in a single invocation",
        discussion: """
        Reads a JSON array of step objects from --script <path> or stdin and runs
        them serially with shared target resolution and variable capture.

        See the script-exec capability spec for the full schema.
        """
    )

    @Option(name: .long, help: "Path to JSON script file (omit to read from stdin)")
    var script: String?

    @Option(name: .long, help: "Maximum number of steps allowed in one invocation")
    var maxSteps: Int = ScriptInterpreter.defaultMaxSteps

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let source: String
        if let scriptPath = script {
            let path = (scriptPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw SafariBrowserError.fileNotFound(scriptPath)
            }
            source = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            source = readStdinAsString()
        }

        let interpreter = ScriptInterpreter(maxSteps: maxSteps)
        let results = try await interpreter.run(source: source, target: target)
        printResults(results)
    }

    private func readStdinAsString() -> String {
        var collected = Data()
        let stdin = FileHandle.standardInput
        while case let chunk = stdin.availableData, !chunk.isEmpty {
            collected.append(chunk)
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    private func printResults(_ results: [StepResult]) {
        let json = StepResult.encodeArray(results)
        print(json)
    }
}
