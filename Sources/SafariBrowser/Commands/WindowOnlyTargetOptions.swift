import ArgumentParser

/// Window-only targeting for commands whose underlying implementation is
/// necessarily window-scoped — `close` (AppleScript `close current tab of
/// window N`), `screenshot` (CGWindowListCopyWindowInfo window ID),
/// `pdf` / `upload --native` (System Events keystrokes that target the
/// frontmost window by definition).
///
/// These commands cannot accept `--url` / `--tab` / `--document` because
/// the corresponding operations have no document-scoped primitive, so we
/// expose a dedicated `@OptionGroup` that only parses `--window` rather
/// than reusing `TargetOptions` and rejecting the other flags at runtime.
/// Type-safety is cheap here — this struct is ~15 lines — and the
/// argument parser surfaces the restriction to the user at parse time
/// rather than after they hit enter and a command half-runs (#23).
struct WindowOnlyTargetOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Target the Nth Safari window (1-indexed). Defaults to the front window."
    )
    var window: Int?

    func validate() throws {
        if let w = window, w < 1 {
            throw ValidationError("--window must be >= 1 (1-indexed), got \(w)")
        }
    }
}
