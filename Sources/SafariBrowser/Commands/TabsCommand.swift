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
        // #52: honor --profile by resolving the requested profile's window
        // (its front window, or --window N validated to live in the profile)
        // and listing that window's tabs. Reuses the #47 profile filter via
        // resolveToConcreteTarget — no listTabs change needed.
        var window = target.window
        if let profile = target.resolveProfile() {
            let base: SafariBridge.TargetDocument = target.window.map { .windowIndex($0) } ?? .frontWindow
            let concrete = try await SafariBridge.resolveToConcreteTarget(
                base,
                firstMatch: target.firstMatch,
                warnWriter: TargetOptions.stderrWarnWriter,
                profile: profile
            )
            switch concrete {
            case .windowIndex(let n): window = n
            case .windowTab(let n, _): window = n
            default: break
            }
        }
        let tabs = try await SafariBridge.listTabs(window: window)
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
