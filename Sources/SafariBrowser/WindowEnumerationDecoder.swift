import Foundation

extension SafariBridge {

    /// Decode the output of `listAllWindowsScript` (#355).
    ///
    /// The script returns one AppleScript list per window,
    /// `{w, winID, winName, currentIdx, urls, names}`, and the text arrives in AppleScript source form
    /// (`AppleScriptSourceForm`) on both the stateless and the daemon path. Page titles, window names
    /// and URLs are quoted strings in that text, so no character in them can add, remove or alter a
    /// row; the rows and window ids below depend only on the list structure. The profile is the
    /// exception: it is parsed from the window name, and a default-profile window's name is its page
    /// title, so a title such as `Work — x` gives that window the profile `Work` (#364).
    ///
    /// A list the script cannot produce fails the command with `windowEnumerationCorrupt`
    /// (maintainer decision for #355: fail rather than drop rows). So does one state the script
    /// produces only while Safari's windows change under it: two windows reporting one id (a window
    /// opened or raised mid-enumeration is read at two z-order positions). The checks:
    /// 1. the text parses as source form and is a list (an empty text is not; no windows is `{}`);
    /// 2. every item is a list of six elements;
    /// 3. its first element is an integer equal to its 1-based position;
    /// 4. the window id is an integer or `missing value`; the window name is text or `missing value`;
    /// 5. the current-tab index is an integer; the URL and name lists are lists of equal length whose
    ///    items are text or `missing value`;
    /// 6. a window with no tabs has current-tab index 0; a window with tabs has one of at least 1;
    /// 7. no two windows report the same window id.
    /// A window with tabs whose current-tab index is above its tab count is listed with no tab
    /// current (`currentTabIndex` 0, every `isCurrent` false): a tab opened and made current between
    /// `count of tabs` and `index of current tab` leaves the index past the tabs read. Before #355
    /// such a window also had no tab marked current, but `currentTabIndex` was 1, so a resolver took
    /// tab 1 for the current tab and skipped switching to it.
    /// `missing value` decodes to an empty URL, title or window name and to no window id. The reason
    /// names positions, counts and kinds of value only, never text from the list (#227).
    static func decodeWindowEnumeration(_ text: String) throws -> [WindowInfo] {
        let value: AppleScriptValue
        do {
            value = try AppleScriptSourceForm.parse(text)
        } catch let error as AppleScriptSourceForm.ParseError {
            throw SafariBrowserError.windowEnumerationCorrupt(reason: "the list could not be read (\(error.description))")
        }
        guard case .list(let items) = value else {
            throw corrupt("the result is \(kind(of: value)), not a list")
        }
        var windows: [WindowInfo] = []
        var windowOfID: [Int: Int] = [:]
        for (offset, item) in items.enumerated() {
            let position = offset + 1
            let window = try decodeWindowRecord(item, position: position)
            if let id = window.windowID {
                if let earlier = windowOfID[id] {
                    throw corrupt("windows \(earlier) and \(position) report the same window id", kind: .windowsChanged)
                }
                windowOfID[id] = position
            }
            windows.append(window)
        }
        return windows
    }

    private static func decodeWindowRecord(_ item: AppleScriptValue, position: Int) throws -> WindowInfo {
        guard case .list(let fields) = item else {
            throw corrupt("item \(position) is \(kind(of: item)), not a list")
        }
        guard fields.count == 6 else {
            throw corrupt("item \(position) has \(fields.count) elements, not 6")
        }
        guard case .integer(let windowIndex) = fields[0], windowIndex == position else {
            throw corrupt("item \(position) does not carry window number \(position) (\(kind(of: fields[0])))")
        }
        let windowID: Int?
        switch fields[1] {
        case .integer(let id): windowID = id
        case .missingValue: windowID = nil
        // A real: an id of 2^29 or more arrives as one, and a rerun will not change it. Any
        // other kind of value is a shape problem (default below).
        case .real: throw corrupt("the window id of window \(position) is a real number", kind: .windowIDNotInteger)
        default: throw corrupt("the window id of window \(position) is \(kind(of: fields[1]))")
        }
        let windowName = try textOrEmpty(fields[2], what: "the name of window \(position)")
        guard case .integer(let currentIndex) = fields[3] else {
            throw corrupt("the current tab of window \(position) is \(kind(of: fields[3]))")
        }
        let urls = try textList(fields[4], what: "URL", window: position)
        let titles = try textList(fields[5], what: "title", window: position)
        guard urls.count == titles.count else {
            throw corrupt("window \(position) has \(urls.count) URLs and \(titles.count) titles")
        }
        if urls.isEmpty {
            guard currentIndex == 0 else {
                throw corrupt("window \(position) has no tabs but names tab \(currentIndex) as current")
            }
        } else {
            guard currentIndex >= 1 else {
                throw corrupt("window \(position) has \(urls.count) tabs but names tab \(currentIndex) as current")
            }
        }
        // Past the tabs read: no tab is current (see the doc comment). 0, not 1, so a resolver
        // that compares a tab with `currentTabIndex` never takes tab 1 for the current tab and
        // skips switching to it.
        let current = currentIndex <= urls.count ? currentIndex : 0
        let tabs = urls.indices.map { index in
            TabInWindow(tabIndex: index + 1, url: urls[index], title: titles[index],
                        isCurrent: index + 1 == current)
        }
        return WindowInfo(
            windowIndex: windowIndex,
            // A window without tabs has no current tab; 1 is what every tab-less window carried
            // before #355, and nothing positional reads it when `tabs` is empty.
            currentTabIndex: urls.isEmpty ? 1 : current,
            tabs: tabs,
            profile: UrlMatcher.parseProfile(fromWindowName: windowName).profile,
            windowID: windowID
        )
    }

    private static func textList(_ value: AppleScriptValue, what: String, window: Int) throws -> [String] {
        guard case .list(let items) = value else {
            throw corrupt("the \(what)s of window \(window) are \(kind(of: value)), not a list")
        }
        return try items.enumerated().map { offset, item in
            try textOrEmpty(item, what: "\(what) \(offset + 1) of window \(window)")
        }
    }

    private static func textOrEmpty(_ value: AppleScriptValue, what: String) throws -> String {
        switch value {
        case .text(let text): return text
        case .missingValue: return ""
        default: throw corrupt("\(what) is \(kind(of: value))")
        }
    }

    private static func corrupt(_ reason: String, kind: WindowEnumerationProblem = .shape) -> SafariBrowserError {
        .windowEnumerationCorrupt(reason: reason, kind: kind)
    }

    /// A value's kind, for error messages: never its text.
    private static func kind(of value: AppleScriptValue) -> String {
        switch value {
        case .list(let items): return "a list of \(items.count)"
        case .text: return "text"
        case .integer: return "an integer"
        case .real: return "a real number"
        case .missingValue: return "missing value"
        case .other: return "a value of another kind"
        }
    }
}
