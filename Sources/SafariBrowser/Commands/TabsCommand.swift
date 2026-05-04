import ArgumentParser
import Foundation

struct TabsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List all open tabs"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        // `tabs` lists tabs of a window — document-level targeting doesn't
        // make sense, so reject everything except --window (and the no-flag
        // default, which means front window).
        if target.url != nil || target.tab != nil || target.document != nil {
            throw ValidationError(
                "`tabs` only supports --window for targeting; --url, --tab, and --document are not allowed."
            )
        }
    }

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "tabs")
        let tabs = try await SafariBridge.listTabs(window: target.window)
        if json {
            let arr = tabs.map { ["index": $0.index, "title": $0.title, "url": $0.url] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            for tab in tabs {
                print("\(tab.index)\t\(tab.title)\t\(tab.url)")
            }
        }
    }
}
