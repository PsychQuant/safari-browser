import ArgumentParser
import Foundation

struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll the page, or a nested scrollable container (--selector)"
    )

    @Argument(help: "Direction: up, down, left, or right")
    var direction: String

    @Argument(help: "Pixels to scroll (default: 500)")
    var pixels: Int = 500

    /// #77: message lists, feeds and other nested scrollable containers do not
    /// move with `window.scrollBy` — the page itself often has nothing to
    /// scroll. Without this the options were hand-written `el.scrollTop` JS per
    /// site, or `press PageUp` after clicking the container to focus it.
    @Option(name: .long, help: "CSS selector of a scrollable container (default: the page)")
    var selector: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (x, y): (Int, Int) = switch direction.lowercased() {
        case "down": (0, pixels)
        case "up": (0, -pixels)
        case "right": (pixels, 0)
        case "left": (-pixels, 0)
        default:
            throw ValidationError("Direction must be up, down, left, or right")
        }

        guard let selector else {
            // Page-level path unchanged.
            _ = try await SafariBridge.doJavaScript("window.scrollBy(\(x), \(y))", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
            return
        }

        let result = try await SafariBridge.doJavaScript(
            ScrollCommand.containerScrollJS(selector: selector, x: x, y: y),
            target: target.resolve(),
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: target.resolveProfile()
        )

        switch result.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "NOT_FOUND":
            throw SafariBrowserError.elementNotFound(selector)
        case "NOT_SCROLLABLE":
            throw SafariBrowserError.elementNotScrollable(selector: selector)
        case "AT_EDGE":
            // Not an error: reaching the end of a list is a normal outcome, and
            // callers that scroll in a loop depend on it happening. But it is
            // indistinguishable from a successful scroll unless we say so, and
            // a loop that cannot tell them apart never terminates.
            FileHandle.standardError.write(Data(
                "note: \(selector) did not move — already at the \(direction.lowercased()) edge of its scroll range.\n".utf8))
        default:
            break
        }
    }

    /// Scrolls the container and reports what actually happened. Exposed for
    /// unit tests, which assert the JS distinguishes the three outcomes rather
    /// than collapsing them into a silent no-op.
    ///
    /// The distinction matters because both no-op cases look identical from
    /// outside: `scrollBy` on a non-scrollable element and `scrollBy` on an
    /// element already at its edge both return undefined and change nothing.
    /// Conflating them hides the common mistake — a selector that matched a
    /// wrapper rather than the element that actually carries the overflow.
    static func containerScrollJS(selector: String, x: Int, y: Int) -> String {
        """
        (function(){
          var el = \(selector.resolveRefJS);
          if (!el) return 'NOT_FOUND';
          var beforeTop = el.scrollTop, beforeLeft = el.scrollLeft;
          el.scrollBy(\(x), \(y));
          if (el.scrollTop !== beforeTop || el.scrollLeft !== beforeLeft) return 'OK';
          var canScrollY = el.scrollHeight > el.clientHeight;
          var canScrollX = el.scrollWidth > el.clientWidth;
          return (canScrollY || canScrollX) ? 'AT_EDGE' : 'NOT_SCROLLABLE';
        })()
        """
    }
}
