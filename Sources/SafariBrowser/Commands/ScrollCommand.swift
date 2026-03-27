import ArgumentParser

struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll the page (up/down/left/right)"
    )

    @Argument(help: "Direction: up, down, left, or right")
    var direction: String

    @Argument(help: "Pixels to scroll (default: 500)")
    var pixels: Int = 500

    func run() async throws {
        let (x, y): (Int, Int) = switch direction.lowercased() {
        case "down": (0, pixels)
        case "up": (0, -pixels)
        case "right": (pixels, 0)
        case "left": (-pixels, 0)
        default:
            throw ValidationError("Direction must be up, down, left, or right")
        }
        _ = try await SafariBridge.doJavaScript("window.scrollBy(\(x), \(y))")
    }
}
