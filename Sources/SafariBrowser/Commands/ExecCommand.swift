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

        // Section 10 v2 of `script-exec-command`: when daemon is opt-in
        // active AND every step in the script uses an in-process-supported
        // command, send the entire script as a single `exec.runScript`
        // request. This eliminates per-step subprocess + socket-handshake
        // overhead from the client path. Otherwise (daemon off, or any
        // step uses an unsupported command) fall through to the local
        // interpreter which uses the SubprocessStepDispatcher.
        if SafariBridge.shouldUseDaemonAuto(),
           let parsed = try? ScriptInterpreter.parseScript(source: source, maxSteps: maxSteps),
           Self.allStepsSupported(parsed),
           let results = try await runViaDaemon(steps: parsed) {
            print(results)
            return
        }

        let interpreter = ScriptInterpreter(maxSteps: maxSteps)
        let results = try await interpreter.run(source: source, target: target)
        printResults(results)
    }

    /// Returns true when every step's `cmd` is in
    /// `InProcessStepDispatcher.supportedCommands`. Used as a pre-flight
    /// gate so the client doesn't send a script that would partially fail
    /// in the daemon path.
    private static func allStepsSupported(_ steps: [ScriptStep]) -> Bool {
        for step in steps {
            if !InProcessStepDispatcher.isSupported(step.cmd) {
                return false
            }
        }
        return true
    }

    /// Send the script to the daemon's `exec.runScript` handler. Returns
    /// the encoded result-array string on success, nil if any transport
    /// or handler-side error occurs (caller falls through to local path).
    private func runViaDaemon(steps: [ScriptStep]) async throws -> String? {
        // Re-encode steps + target as the envelope the handler expects.
        let stepsJSON = steps.map { step in step.toDictionary() }
        let envelope: [String: Any] = [
            "steps": stepsJSON,
            "targetArgs": ScriptInterpreter.encodeTargetArgs(target),
            "maxSteps": maxSteps,
        ]
        let envelopeData: Data
        do {
            envelopeData = try JSONSerialization.data(withJSONObject: envelope, options: [])
        } catch {
            return nil
        }

        let name = DaemonClient.resolveName(flag: nil)
        do {
            let resultData = try await DaemonClient.sendRequest(
                name: name,
                method: "exec.runScript",
                params: envelopeData,
                requestId: Int.random(in: 1...Int.max),
                timeout: 60.0
            )
            // Handler returns `{"results": "<json string of result array>"}`.
            guard let dict = try JSONSerialization.jsonObject(with: resultData, options: []) as? [String: Any],
                  let results = dict["results"] as? String else {
                return nil
            }
            return results
        } catch let err as DaemonClient.Error {
            // Domain errors (e.g. ambiguousWindowMatch) propagate; transport
            // errors fall through to the local subprocess path silently.
            if err.fallbackReason == nil {
                throw err
            }
            FileHandle.standardError.write(Data("[daemon fallback: \(err.fallbackReason ?? "")]\n".utf8))
            return nil
        }
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
