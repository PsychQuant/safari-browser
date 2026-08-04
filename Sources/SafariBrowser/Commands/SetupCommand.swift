import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

/// #98: the one place safari-browser is allowed to raise a system dialog.
///
/// Every other command detects permissions and refuses with guidance, because
/// the Non-Interference contract forbids interrupting the user — a background
/// automation run must never pop an alert. That left no way to *get* the
/// permissions: the guidance says "add it in System Settings", but a CLI binary
/// is usually absent from those lists, and adding it by hand means locating a
/// path buried in `~/bin` or `.build/release`.
///
/// A dialog the user asked for by typing this command is not an interruption,
/// so the request calls live here and nowhere else. Nothing about the other
/// commands' behavior changes.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Show and request the macOS permissions safari-browser needs"
    )

    @Flag(name: .long, help: "Report status only; never raise a permission dialog")
    var check = false

    @Flag(name: .long, help: "Open the relevant System Settings panes as well")
    var openSettings = false

    /// Whether the current permission state is complete enough to be worth a
    /// zero exit. Pure so the exit-code contract is testable.
    static func allGranted(accessibility: Bool, screenRecording: Bool) -> Bool {
        accessibility && screenRecording
    }

    /// Description of a permission's state, worded so "granted" and "we cannot
    /// tell" never read the same. Several of this tool's past bugs came from
    /// treating an unreadable state as a good one.
    static func statusLine(name: String, granted: Bool, usedFor: String) -> String {
        "\(granted ? "✓" : "✗") \(name): \(granted ? "granted" : "NOT granted") — \(usedFor)"
    }

    func run() async throws {
        let binaryPath = SetupCommand.resolvedBinaryPath()

        print("safari-browser setup")
        print("")
        // che-ical-mcp surfaces this because the grant attaches to a specific
        // file, and users routinely authorize the wrong copy — a stale ~/bin
        // build instead of the one they just made, or vice versa.
        print("Binary being authorized:")
        print("  \(binaryPath)")
        print("")

        var accessibility = AXIsProcessTrusted()
        var screenRecording = CGPreflightScreenCaptureAccess()

        print("Current status:")
        print("  " + SetupCommand.statusLine(
            name: "Accessibility", granted: accessibility,
            usedFor: "window resolution for screenshot/pdf/upload --native, and blocked-dialog detection"))
        print("  " + SetupCommand.statusLine(
            name: "Screen Recording", granted: screenRecording,
            usedFor: "the actual pixel capture in screenshot"))
        print("")

        if check {
            print("(--check: no dialogs raised)")
            throw ExitCode(SetupCommand.allGranted(
                accessibility: accessibility, screenRecording: screenRecording) ? 0 : 1)
        }

        if SetupCommand.allGranted(accessibility: accessibility, screenRecording: screenRecording) {
            print("Both permissions are already granted — nothing to request.")
            return
        }

        if !SetupCommand.isInteractive() {
            // The prompts are useless without someone to click them, and a
            // background run that silently spawns dialogs is exactly what the
            // Non-Interference contract exists to prevent.
            print("WARNING: this does not look like an interactive terminal.")
            print("A permission dialog needs someone present to answer it.")
            print("Run `safari-browser setup` yourself in Terminal, or use --check to only report status.")
            throw ExitCode(1)
        }

        if !accessibility {
            print("Requesting Accessibility…")
            print("  A dialog will appear. If it does not, the binary may already be")
            print("  listed but switched off — use --open-settings and enable it there.")
            // The prompting variant. AXIsProcessTrusted() (used everywhere
            // else) is the silent one and never adds the binary to the list.
            // The constant `kAXTrustedCheckOptionPrompt` is a global `var` in
            // the SDK, which Swift 6 rejects as shared mutable state. Its value
            // is this fixed string; pinned by a test so a typo cannot silently
            // turn the prompt off (an unrecognised key is ignored, not an
            // error — the call would just quietly stop prompting).
            let options = [SetupCommand.axPromptOptionKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            print("")
        }

        if !screenRecording {
            print("Requesting Screen Recording…")
            // Unlike Accessibility, this one returns the post-request state
            // directly rather than requiring a re-check.
            let granted = CGRequestScreenCaptureAccess()
            print("  \(granted ? "granted" : "not granted — see the note below")")
            print("")
        }

        if openSettings {
            SetupCommand.openSettingsPanes(
                accessibility: !accessibility, screenRecording: !screenRecording)
        }

        // Re-read: Accessibility in particular does not flip within the process
        // that requested it, so report what is actually true now rather than
        // implying the request succeeded.
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()

        print("Status after requesting:")
        print("  " + SetupCommand.statusLine(
            name: "Accessibility", granted: accessibility, usedFor: "see above"))
        print("  " + SetupCommand.statusLine(
            name: "Screen Recording", granted: screenRecording, usedFor: "see above"))
        print("")
        print(SetupCommand.afterNotes)

        throw ExitCode(SetupCommand.allGranted(
            accessibility: accessibility, screenRecording: screenRecording) ? 0 : 1)
    }

    /// What a user needs to know when the status did not flip. Kept as one
    /// string so the wording is pinned by a test — this is the text people read
    /// at the exact moment the tool looks broken.
    static let afterNotes = """
        Notes:
          • macOS applies both grants at process start, so a permission granted just now
            takes effect on the NEXT run, not this one. Re-run to confirm.
          • The grant attaches to whatever macOS holds responsible for this process. For a
            CLI launched from a shell that is often the terminal app (Terminal, iTerm, your
            IDE) rather than the binary above — check System Settings for both names.
          • Screen Recording cannot be granted from a dialog if the app was never listed:
            macOS only offers the prompt once. Use --open-settings and add it with '+'.
        """

    /// Literal value of `kAXTrustedCheckOptionPrompt`. Passing an unknown key
    /// to `AXIsProcessTrustedWithOptions` is silently ignored rather than
    /// rejected, so a typo here would disable prompting with no symptom.
    static let axPromptOptionKey = "AXTrustedCheckOptionPrompt"

    /// Absolute path of the running binary — symlinks resolved, since System
    /// Settings shows the real file and a `~/bin` symlink would send the reader
    /// looking for a name that is not in the list.
    static func resolvedBinaryPath() -> String {
        let raw = CommandLine.arguments.first ?? "safari-browser"
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        return url.path
    }

    /// stdin AND stdout both attached to a terminal. Either one alone is
    /// satisfied by a pipe on the other side, which is how automation runs.
    static func isInteractive() -> Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1
            && isatty(FileHandle.standardOutput.fileDescriptor) == 1
    }

    static func openSettingsPanes(accessibility: Bool, screenRecording: Bool) {
        if accessibility {
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        if screenRecording {
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func openURL(_ string: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [string]
        try? proc.run()
        proc.waitUntilExit()
    }
}
