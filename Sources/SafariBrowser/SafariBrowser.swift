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
            PDFCacheCommand.self,
            MCPCommand.self,
            MCPWorkerCommand.self,
            MCPSupervisorCommand.self,
            MCPPersistentWorkerCommand.self,
        ]
    )

    /// Persistent workers use the same execution boundary without exiting.
    static func main() async {
        if ProcessInfo.processInfo.environment[MCPWorkerContext.directKey] == MCPIsolatedBootstrap.contextValue {
            do { try MCPIsolatedBootstrap.run() }
            catch {
                try? FileHandle.standardError.write(contentsOf: Data("Invalid isolated worker bootstrap.\n".utf8))
                Foundation.exit(64)
            }
        }
        let code = await CLIExecution.execute()
        Foundation.exit(code)
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
