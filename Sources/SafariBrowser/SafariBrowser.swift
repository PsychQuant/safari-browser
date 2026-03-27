import ArgumentParser

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
            IsCommand.self,
            CookiesCommand.self,
            StorageCommand.self,
            MouseCommand.self,
            ConsoleCommand.self,
            ErrorsCommand.self,
            TabsCommand.self,
            TabCommand.self,
            WaitCommand.self,
            BackCommand.self,
            ForwardCommand.self,
            ReloadCommand.self,
            CloseCommand.self,
        ]
    )
}
