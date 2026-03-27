import ArgumentParser
import Foundation

struct TabsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List all open tabs"
    )

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func run() async throws {
        let tabs = try await SafariBridge.listTabs()
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
