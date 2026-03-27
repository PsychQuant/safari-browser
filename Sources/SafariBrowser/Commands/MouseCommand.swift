import ArgumentParser

struct MouseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mouse",
        abstract: "Mouse events (move, down, up, wheel)",
        subcommands: [
            MouseMove.self,
            MouseDown.self,
            MouseUp.self,
            MouseWheel.self,
        ]
    )
}

struct MouseMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move mouse to coordinates"
    )

    @Argument(help: "X coordinate") var x: Int
    @Argument(help: "Y coordinate") var y: Int

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "document.elementFromPoint(\(x),\(y)).dispatchEvent(new MouseEvent('mousemove',{clientX:\(x),clientY:\(y),bubbles:true}))"
        )
    }
}

struct MouseDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "down",
        abstract: "Dispatch mousedown event"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "(document.activeElement||document.body).dispatchEvent(new MouseEvent('mousedown',{bubbles:true}))"
        )
    }
}

struct MouseUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Dispatch mouseup event"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "(document.activeElement||document.body).dispatchEvent(new MouseEvent('mouseup',{bubbles:true}))"
        )
    }
}

struct MouseWheel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wheel",
        abstract: "Dispatch wheel event"
    )

    @Argument(help: "Delta Y (positive = scroll down)") var deltaY: Int

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "document.dispatchEvent(new WheelEvent('wheel',{deltaY:\(deltaY),bubbles:true}))"
        )
    }
}
