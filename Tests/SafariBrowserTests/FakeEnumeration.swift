import Foundation
@testable import SafariBrowser

/// The one place tests build what `SafariBridge.listAllWindowsScript` returns (#355): AppleScript
/// source form, `{{w, winID, winName, currentIdx, urls, names}, …}`. A fake Safari answers the
/// enumeration script with `FakeEnumeration.sourceForm(...)`; if the wire format changes again, only
/// this file changes.
///
/// The quoting is written here on purpose rather than calling `AppleScriptSourceForm.render`, so the
/// fixtures are an independent oracle; `FakeEnumerationTests` checks that both agree with the real
/// `osascript -s s`.
enum FakeEnumeration {

    struct Window {
        /// `nil` writes `missing value` (a window whose id could not be read).
        var id: Int?
        /// `nil` writes `missing value`. Safari writes `<profile> — <title>` for a profile window.
        var name: String?
        /// 1-based index of the current tab; ignored for a window without tabs (written as 0).
        var currentTab: Int
        var tabs: [(url: String, title: String)]

        init(id: Int?, name: String?, currentTab: Int = 1, tabs: [(url: String, title: String)]) {
            self.id = id
            self.name = name
            self.currentTab = currentTab
            self.tabs = tabs
        }

        /// A window of `profile` (no profile: `nil`) whose tabs have the given URLs, titled `Tab N`,
        /// with the first tab current and named in the window name — the shape most fakes use.
        static func titledTabs(id: Int?, profile: String?, urls: [String], currentTab: Int = 1) -> Window {
            let tabs = urls.enumerated().map { (url: $0.element, title: "Tab \($0.offset + 1)") }
            let current = tabs.isEmpty ? "" : tabs[max(0, min(currentTab, tabs.count) - 1)].title
            return Window(id: id, name: profile.map { "\($0) — \(current)" } ?? current,
                          currentTab: currentTab, tabs: tabs)
        }
    }

    /// The enumeration text for these windows, numbered 1, 2, 3 … in order.
    static func sourceForm(_ windows: [Window]) -> String {
        let records = windows.enumerated().map { offset, window -> String in
            let id = window.id.map(String.init) ?? "missing value"
            let name = window.name.map(quote) ?? "missing value"
            let current = window.tabs.isEmpty ? 0 : window.currentTab
            let urls = window.tabs.map { quote($0.url) }.joined(separator: ", ")
            let titles = window.tabs.map { quote($0.title) }.joined(separator: ", ")
            return "{\(offset + 1), \(id), \(name), \(current), {\(urls)}, {\(titles)}}"
        }
        return "{" + records.joined(separator: ", ") + "}"
    }

    /// The enumeration text for windows already in `WindowInfo` form. The window name is
    /// `<profile> — <current tab's title>`, or the title alone without a profile, which is what
    /// `decodeWindowEnumeration` reads the profile back from.
    static func sourceForm(_ windows: [SafariBridge.WindowInfo]) -> String {
        sourceForm(windows.map { info in
            let current = info.tabs.first(where: \.isCurrent)?.title ?? ""
            return Window(id: info.windowID,
                          name: info.profile.map { "\($0) — \(current)" } ?? current,
                          currentTab: info.tabs.first(where: \.isCurrent)?.tabIndex ?? info.currentTabIndex,
                          tabs: info.tabs.map { (url: $0.url, title: $0.title) })
        })
    }

    /// A quoted AppleScript string: `"` → `\"`, `\` → `\\`, every other character as itself.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            if scalar == "\"" || scalar == "\\" { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out + "\""
    }

    /// Whether `script` is the enumeration script.
    static func isEnumeration(_ script: String) -> Bool {
        script == SafariBridge.listAllWindowsScript
    }
}
