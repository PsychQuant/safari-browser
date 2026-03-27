import ArgumentParser

struct DragCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Drag element from source to target"
    )

    @Argument(help: "Source CSS selector or @ref")
    var source: String

    @Argument(help: "Target CSS selector or @ref")
    var target: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript("""
            (function(){
                var src = \(source.resolveRefJS);
                if (!src) return 'SRC_NOT_FOUND';
                var dst = \(target.resolveRefJS);
                if (!dst) return 'DST_NOT_FOUND';
                var dt = new DataTransfer();
                src.dispatchEvent(new DragEvent('dragstart', {bubbles: true, dataTransfer: dt}));
                dst.dispatchEvent(new DragEvent('dragover', {bubbles: true, dataTransfer: dt}));
                dst.dispatchEvent(new DragEvent('drop', {bubbles: true, dataTransfer: dt}));
                src.dispatchEvent(new DragEvent('dragend', {bubbles: true, dataTransfer: dt}));
                return 'OK';
            })()
            """)
        if result == "SRC_NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(source)
        }
        if result == "DST_NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(target)
        }
    }
}
