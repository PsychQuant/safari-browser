import Foundation
import Security

/// The single assessment used by runtime FDA guidance and the install guard.
/// No human-readable codesign output or pathname text participates in policy.
enum SignatureAssessment {
    enum Verdict: Equatable {
        case missingFile
        case unavailable(operation: String, status: OSStatus?)
        case unsigned
        case invalidSeal(OSStatus)
        case adHoc(team: String?)
        case missingEntitlement(name: String, present: Bool)
        case unknownRequirement(String)
        case unsatisfiedRequirement(requirement: String, status: OSStatus)
        case durable(shape: String, requirement: String)
    }

    static func evaluate(at url: URL, requiredEntitlement: String? = nil) -> Verdict {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        if createStatus != errSecSuccess {
            if !FileManager.default.fileExists(atPath: url.path) { return .missingFile }
            if createStatus == errSecCSUnsigned { return .unsigned }
            return .unavailable(operation: "read code", status: createStatus)
        }
        guard let staticCode = code else { return .unavailable(operation: "read code", status: nil) }
        // Bundle resource edits do not answer whether its code's DR is durable.
        // Info.plist validation stays enabled. Every executable slice is checked.
        // @mutant(all-architecture-seals) kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures => kSecCSDoNotValidateResources
        let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures)
        let sealStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, nil)
        if sealStatus != errSecSuccess {
            // @mutant(unsigned-distinct) sealStatus == errSecCSUnsigned => false
            if sealStatus == errSecCSUnsigned { return .unsigned }
            return .invalidSeal(sealStatus)
        }
        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            return .unavailable(operation: "read signing information", status: infoStatus)
        }
        let signFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if signFlags & 0x0002 != 0 { // kSecCodeSignatureAdhoc
            return .adHoc(team: info[kSecCodeInfoTeamIdentifier as String] as? String)
        }
        // Ad-hoc is classified before install-specific entitlement checks.
        if let want = requiredEntitlement {
            let ents = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            let granted: Bool = {
                guard let v = ents?[want] else { return false }
                // @mutant(ent-false-granted) n.boolValue && CFGetTypeID(n) == CFBooleanGetTypeID() => true
                //   R7. Reverting accepts an entitlement explicitly set to <false/> —
                //   a signature that spells out it does NOT hold the permission.
                if let n = v as? NSNumber { return n.boolValue && CFGetTypeID(n) == CFBooleanGetTypeID() }
                // @mutant(ent-nonbool-granted) return false => return true
                //   R8. Reverting makes every non-boolean value a yes, so
                //   <string>false</string> and <array/> satisfy the gate.
                return false
            }()
            // @mutant(ent-gate-open) !granted => false
            //   R6/R7. Reverting removes the gate's verdict entirely, so a binary
            //   without the entitlement reports success instead of 7.
            if !granted { return .missingEntitlement(name: want, present: ents?[want] != nil) }
        }
        var reqRef: SecRequirement?
        let reqStatus = SecCodeCopyDesignatedRequirement(staticCode, [], &reqRef)
        guard reqStatus == errSecSuccess, let requirement = reqRef else {
            return .unavailable(operation: "read designated requirement", status: reqStatus)
        }
        var textRef: CFString?
        let textStatus = SecRequirementCopyString(requirement, [], &textRef)
        guard textStatus == errSecSuccess, let drText = textRef as String? else {
            return .unavailable(operation: "render designated requirement", status: textStatus)
        }
        // Only the canonical requirement object's text is matched, anchored;
        // opaque quoted values cannot introduce a structural clause.
        let ident = #"identifier ("([^"\\]|\\.)*"|[A-Za-z0-9_.\-]+)"#
        let str = #"("([^"\\]|\\.)*"|[A-Za-z0-9_.\-]+)"#
        let devIDOIDs = #"certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.6\] /\* exists \*/ and certificate leaf\[field\.1\.2\.840\.113635\.100\.6\.1\.13\] /\* exists \*/"#

        let shapes: [(String, String)] = [
            // What `install-signed` produces: Developer ID with hardened runtime.
            ("Developer ID",
             #"^\#(ident) and anchor apple generic and \#(devIDOIDs) and certificate leaf\[subject\.OU\] = \#(str)$"#),
            // What Apple's own binaries carry (/bin/ls and friends).
            ("Apple system",
             // @mutant(shape-unanchored-apple) ^\#(ident) and anchor apple$ => \#(ident) and anchor apple
             //   R4/R5. Reverting matches the Apple-system shape as a SUBSTRING, so a
             //   requirement that merely starts that way — an anchored one with an
             //   extra version pin — is reported as a shape this tool knows.
             #"^\#(ident) and anchor apple$"#),
            // What an Apple Development certificate produces. Recognised deliberately:
            // this tool answers "is the grant durable", and that requirement is as
            // identity-bound as the Developer ID one. Whether the certificate is
            // specifically Developer ID is `install-signed`'s contract, asserted there.
            ("Apple Development",
             #"^\#(ident) and anchor apple generic and certificate leaf\[subject\.CN\] = \#(str) and certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.1\] /\* exists \*/$"#),
        ]

        var shape: String?
        for (name, pattern) in shapes {
            if drText.range(of: pattern, options: [.regularExpression]) != nil {
                shape = name
                break
            }
        }

        guard let matchedShape = shape else { return .unknownRequirement(drText) }
        let satisfies = SecStaticCodeCheckValidity(staticCode, checkFlags, requirement)
        guard satisfies == errSecSuccess else {
            return .unsatisfiedRequirement(requirement: drText, status: satisfies)
        }
        return .durable(shape: matchedShape, requirement: drText)
    }
}
