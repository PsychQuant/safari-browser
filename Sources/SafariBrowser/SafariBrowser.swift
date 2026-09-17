import ArgumentParser
import Foundation

@main
struct SafariBrowser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safari-browser",
        abstract: "macOS native browser automation via Safari + AppleScript",
        subcommands: [
            OpenCommand.self,
            SnapshotCommand.self,
            JSCommand.self,
            GetCommand.self,
            ClickCommand.self,
            FillCommand.self,
            TypeCommand.self,
            SelectCommand.self,
            HoverCommand.self,
            ScrollCommand.self,
            PressCommand.self,
            FocusCommand.self,
            CheckCommand.self,
            UncheckCommand.self,
            DblclickCommand.self,
            UploadCommand.self,
            ScrollIntoViewCommand.self,
            FindCommand.self,
            HighlightCommand.self,
            ScreenshotCommand.self,
            SaveImageCommand.self,
            PdfCommand.self,
            DragCommand.self,
            SetCommand.self,
            IsCommand.self,
            CookiesCommand.self,
            StorageCommand.self,
            MouseCommand.self,
            ConsoleCommand.self,
            ErrorsCommand.self,
            SetupCommand.self,
            DialogCommand.self,
            TabsCommand.self,
            TabCommand.self,
            DocumentsCommand.self,
            WaitCommand.self,
            BackCommand.self,
            ForwardCommand.self,
            ReloadCommand.self,
            CloseCommand.self,
            DaemonCommand.self,
            ExecCommand.self,
            HistoryCommand.self,
            BookmarksCommand.self,
            CloudTabsCommand.self,
            DownloadsCommand.self,
            MCPCommand.self,
            MCPWorkerCommand.self,
        ]
    )

    /// Custom entry point mirroring ArgumentParser's default async `main()`,
    /// but augmenting the error path with a targeted hint (#69) when a known
    /// targeting flag and its value arrive glued into a single argv element —
    /// the classic zsh `LOCK="--url report"; cmd $LOCK` footgun (zsh, unlike
    /// bash, does not word-split an unquoted parameter) or a user-quoted
    /// `cmd "--url report"`. Everything else is byte-identical to the default.
    static func main() async {
        let timing = PerformanceTrace.isEnabled(ProcessInfo.processInfo.environment)
            ? PerformanceTrace.Collector() : nil
        let commandSpan = timing?.begin(.command)
        let context = timing.map { PerformanceTrace.Context(collector: $0, parentID: commandSpan) }
        func finishTiming(_ status: PerformanceTrace.Outcome) {
            if let commandSpan { timing?.end(commandSpan, outcome: status) }
            if let summary = timing?.finish(status: status) { PerformanceTrace.emit(summary) }
        }
        do {
            try await PerformanceTrace.$context.withValue(context) {
                try MCPWorkerContext.validate(environment: ProcessInfo.processInfo.environment,
                                              currentImage: MCPWorkerContext.currentImageIdentifier)
                var command = try parseAsRoot()
                // Finish and discard host timing: each worker/handler owns its
                // own request, rather than inheriting a host-lifetime collector.
                if command is DaemonServeCommand || command is MCPCommand {
                    _ = timing?.finish(status: .ok)
                }
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
            finishTiming(.ok)
        } catch {
            finishTiming(exitCode(for: error).rawValue == 0 ? .ok : .error)
            if let hint = gluedFlagHint(forErrorMessage: message(for: error)) {
                let out = fullMessage(for: error) + "\n" + hint + "\n"
                FileHandle.standardError.write(Data(out.utf8))
                Foundation.exit(exitCode(for: error).rawValue)
            }
            exit(withError: error)
        }
    }

    /// Pure helper (#69): given an ArgumentParser error message, return a
    /// hint when it reports an unknown option whose text is a known targeting
    /// flag followed by a space and a value — i.e. the flag and its value
    /// were passed as ONE argument. `nil` for genuinely-unknown flags or
    /// unrelated errors, so the default error output is preserved.
    static func gluedFlagHint(forErrorMessage message: String) -> String? {
        guard let open = message.range(of: "Unknown option '") else { return nil }
        let rest = message[open.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let token = String(rest[..<close])                 // e.g. "--url report"
        guard let space = token.firstIndex(of: " ") else { return nil }
        let flag = String(token[..<space])                 // "--url"
        let value = String(token[token.index(after: space)...])  // "report"
        // Only hint when the leading token is a real targeting flag — a
        // genuinely-unknown flag should keep the plain error.
        guard TargetOptions.targetFlagNames.contains(flag) else { return nil }
        return """
        Hint: this looks like a flag and its value passed as a single argument.
              Inline them as two words:  \(flag) \(value)
              In zsh, if using a variable, use an array:  LOCK=(\(flag) \(value)); "${LOCK[@]}"
        """
    }
}
