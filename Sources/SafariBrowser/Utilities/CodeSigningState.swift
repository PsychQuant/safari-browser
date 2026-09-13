import Foundation

/// FDA remediation consumes the same Security assessment as the install guard.
/// A certificate label alone does not establish a durable designated requirement.
enum CodeSigningState: Equatable {
    case durable
    case adHoc
    case unknown

    static func current() -> CodeSigningState {
        state(ofBinaryAt: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    static func state(ofBinaryAt url: URL) -> CodeSigningState {
        switch SignatureAssessment.evaluate(at: url) {
        case .durable: return .durable
        case .adHoc: return .adHoc
        case .missingFile, .unavailable, .unsigned, .invalidSeal,
             .missingEntitlement, .unknownRequirement, .unsatisfiedRequirement:
            return .unknown
        }
    }

    var fullDiskAccessGuidance: String {
        switch self {
        case .durable:
            return """
                This build has a valid identity-bound designated requirement.
                A Full Disk Access grant survives rebuilds only while the signing
                identity and designated requirement stay the same. Changing either
                can require granting access again.

                Grant Full Disk Access to safari-browser:
                  System Settings → Privacy & Security → Full Disk Access → +
                  then choose this binary.
                """
        case .adHoc:
            return """
                This build is ad-hoc signed, so macOS identifies it by its code hash —
                rebuilding the binary can invalidate a Full Disk Access grant you have
                already given it. Two ways forward:

                  1. Install a Developer ID signed build:
                       DEVELOPER_ID=<cert-sha1> make install-signed
                     then add ~/bin/safari-browser in
                       System Settings → Privacy & Security → Full Disk Access

                     This target verifies the signature and atomically replaces
                     the installed binary, without overwriting its existing inode.
                     Keep the same signing identity and designated requirement
                     across rebuilds to retain the grant.

                  2. Grant Full Disk Access to your terminal application instead.
                     Simpler, but far broader — the terminal can then read every file
                     on the system, not just Safari's.
                """
        case .unknown:
            return """
                Grant Full Disk Access before running this command:
                  System Settings → Privacy & Security → Full Disk Access → +
                  then add either this binary or your terminal application.

                This build could not be established as having a durable signature.
                Inspect its signature with the project's shared guard:
                  make verify-install-signature
                To install a verified signed build, use:
                  DEVELOPER_ID=<cert-sha1> make install-signed
                """
        }
    }
}
