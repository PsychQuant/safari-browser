import Foundation

/// How the running binary is signed (#109).
///
/// This matters for exactly one thing: what to tell a user whose Full Disk
/// Access grant is missing. The two states need *different* advice, and
/// generic "grant permission" text sends ad-hoc users down a path that
/// quietly stops working the next time they rebuild.
///
/// Empirically established while diagnosing #109: a bare CLI binary under
/// `~/bin` *can* hold its own FDA grant — a Developer ID signed sibling in
/// that same directory does. safari-browser does not, and the only structural
/// difference between them is the signature. So the deciding factor is
/// signing, not "is it a CLI".
enum CodeSigningState: Equatable {
    /// Signed with a Developer ID certificate. TCC identifies the binary by
    /// its designated requirement, so a grant survives rebuilds.
    case developerID
    /// Ad-hoc signed (`codesign --sign -`), which is what `make install`
    /// produces. No team identifier, no stable designated requirement.
    case adHoc
    /// Could not be determined — `codesign` missing, or unreadable output.
    case unknown

    static func current() -> CodeSigningState {
        state(ofBinaryAt: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    static func state(ofBinaryAt url: URL) -> CodeSigningState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", url.path]
        let pipe = Pipe()
        // codesign writes its description to stderr, not stdout.
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .unknown
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure parser over `codesign -dvv` output, split out so it is testable
    /// without spawning a process or depending on how *this* build is signed.
    static func parse(_ codesignOutput: String) -> CodeSigningState {
        if codesignOutput.contains("Signature=adhoc") {
            return .adHoc
        }
        if codesignOutput.contains("Authority=Developer ID Application") {
            return .developerID
        }
        return .unknown
    }

    /// Remediation text for a missing Full Disk Access grant.
    ///
    /// Ad-hoc builds get the rebuild caveat *and* both escape routes; a
    /// Developer ID build gets the direct instruction, because for it the
    /// grant is durable and pointing at the terminal would hand out a far
    /// broader permission than the tool needs.
    var fullDiskAccessGuidance: String {
        switch self {
        case .developerID:
            return """
                Grant Full Disk Access to safari-browser:
                  System Settings → Privacy & Security → Full Disk Access → +
                  then choose this binary.
                """
        case .adHoc:
            return """
                This build is ad-hoc signed, so macOS identifies it by its code hash —
                rebuilding the binary can invalidate a Full Disk Access grant you have
                already given it. Two ways forward:

                  1. Install a Developer ID signed build (the grant then survives rebuilds):
                       DEVELOPER_ID=<cert-sha1> make sign-developer-id
                       cp .build/release/safari-browser ~/bin/safari-browser
                     then add ~/bin/safari-browser in
                       System Settings → Privacy & Security → Full Disk Access

                     Copy the binary yourself rather than running `make install` — that
                     target re-signs whatever it copies with `codesign --sign -`, which
                     would put you straight back to an ad-hoc binary.

                  2. Grant Full Disk Access to your terminal application instead.
                     Simpler, but far broader — the terminal can then read every file
                     on the system, not just Safari's.
                """
        case .unknown:
            return """
                Grant Full Disk Access before running this command:
                  System Settings → Privacy & Security → Full Disk Access → +
                  then add either this binary or your terminal application.

                The signing state of this build could not be determined, so which of
                the two is durable is unknown here. Check with:
                  codesign -dvv "$(command -v safari-browser)"
                """
        }
    }
}
