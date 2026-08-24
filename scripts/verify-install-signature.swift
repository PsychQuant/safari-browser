#!/usr/bin/env swift
// Will a Full Disk Access grant on this binary still apply later? (#119)
//
// TCC stores the binary's designated requirement (DR) and re-evaluates it, so
// the grant is durable exactly when the DR names an identity the binary keeps
// across rebuilds — rather than its bytes, which change every build.
//
//   0  durable: a recognised identity-bound shape, and the binary satisfies it
//   1  ad-hoc signature — the DR is the content hash, so a rebuild kills it
//   2  no signature, or the check could not run (environment, not a verdict)
//   3  the signature does not validate — TCC will not honour a grant on it
//   4  recognised shape, but this binary cannot satisfy it — grant never applies
//   5  a requirement shape this tool does not recognise — it cannot tell
//
// ── Why this is Swift and not shell ──────────────────────────────────────
//
// Five rounds of review defeated five successive shell implementations. The
// first four each moved the criterion while keeping `grep` as the instrument:
//
//   v1  "the DR does not contain cdhash"    → --preserve-metadata carries an
//                                              identity-bound DR onto an ad-hoc
//                                              signature
//   v2  + "the signature is not ad-hoc"     → sign with one certificate while
//                                              preserving another's DR
//   v3  + "the binary satisfies its own DR" → a DR naming only an identifier
//   v4  "the DR must name anchor/certificate" → identifier "com.foo.anchor"
//
// v5 declared the grep era over: read observable FIELDS, then match the
// designated line whole and anchored. Both halves were still text, and review
// broke both — not by constructing exotic requirements, but with ordinary
// software and an ordinary filename:
//
//   - `codesign --verify` reports a bundle's unsigned SUBCOMPONENT with the
//     words "not signed at all". A real Developer ID app (ACE Studio) came
//     back "no code signature".
//   - It reports bundle resource damage as "a sealed resource is missing or
//     invalid" — nothing to do with the executable's own seal. Anki and
//     Blender, both running fine, were declared SIGKILL-bound, with a
//     `rm -f` prescription.
//   - `codesign -d -r-` writes `Executable=<path>` into the same stream the
//     requirement is read from. A path containing a newline injects a
//     `designated => ...` line of the caller's choosing, and `head -1` takes
//     it. Two byte-identical copies of /bin/ls, opposite verdicts.
//
// The lesson is not "anchor the patterns harder". It is that codesign's
// output is a human-readable diagnostic, and every attempt to use it as a
// data interface has failed in a way its author did not foresee. So this
// version never reads that output at all:
//
//   * Validity is an OSStatus — a number. "Unsigned", "seal broken", and
//     "a bundle resource is missing" are distinct codes, not English that
//     has to be told apart by substring.
//   * The designated requirement is a SecRequirement OBJECT, obtained from
//     the signature. There is exactly one, it carries no path, and nothing
//     else shares its channel — the forged-line attacks have no surface.
//   * Satisfaction is checked by handing that OBJECT back to the API. The
//     requirement is never serialised, re-parsed, or written to a file, so
//     the requirement checked is necessarily the requirement read.
//
// Text appears in exactly one place: deciding whether the requirement is a
// SHAPE we recognise. That string comes from SecRequirementCopyString on the
// object itself, so it describes this binary's real requirement and nothing
// else. An unrecognised shape is exit 5 — an admission, not a verdict.
//
// Resource validation is deliberately off (kSecCSDoNotValidateResources).
// The question is whether TCC will honour a grant on this CODE; a bundle's
// resource seal is a different question, and conflating them is what
// condemned Anki and Blender.
import Foundation
import Security

// Usage: verify-install-signature.swift [--require-shape NAME]
//                                        [--require-entitlement KEY] [path]
//
// The two --require flags exist so `install-signed` can assert its own
// contract through this same API path. Round 5 found it asserting them with
// `codesign -dvv | grep -q "Authority=Developer ID Application"` and
// `codesign -dv --entitlements - | grep -q apple-events` — unanchored
// substring searches over a stream that also echoes the file's path. Those
// greps are gone; both answers now come from the signature itself.
var requiredShape: String?
var requiredEntitlement: String?
var positional: [String] = []
var rest = Array(CommandLine.arguments.dropFirst())
while let head = rest.first {
    rest.removeFirst()
    switch head {
    case "--require-shape":
        guard let v = rest.first else { fatalError("--require-shape needs a value") }
        requiredShape = v; rest.removeFirst()
    case "--require-entitlement":
        guard let v = rest.first else { fatalError("--require-entitlement needs a value") }
        requiredEntitlement = v; rest.removeFirst()
    default:
        positional.append(head)
    }
}
let target = positional.first
    ?? (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/bin/safari-browser"

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func envProblem(_ what: String) -> Never {
    err("✗ \(what)")
    err("  This is an environment problem, not a verdict about \(target).")
    exit(2)
}

// ── 1. Get a handle on the code ──────────────────────────────────────────
var code: SecStaticCode?
let url = URL(fileURLWithPath: target) as CFURL
let createStatus = SecStaticCodeCreateWithPath(url, [], &code)

if createStatus != errSecSuccess {
    if !FileManager.default.fileExists(atPath: target) {
        err("✗ no such file: \(target)")
        exit(2)
    }
    if createStatus == errSecCSUnsigned {
        err("✗ no code signature: \(target)")
        err("  An unsigned binary cannot hold a Full Disk Access grant.")
        exit(2)
    }
    envProblem("could not read \(target) as code (OSStatus \(createStatus))")
}
guard let staticCode = code else {
    envProblem("could not read \(target) as code")
}

// ── 2. Does the signature validate? ─────────────────────────────────────
// A number, not prose — and the number's own meaning comes from Apple via
// SecCopyErrorMessageString rather than from this file's guesses about
// codesign's wording.
//
// Resource validation is off on purpose. A bundle's damaged RESOURCE says
// nothing about whether TCC will honour a grant on the code: TCC evaluates
// the code requirement. Round 5 conflated the two and declared Blender —
// intact seal, one changed resource, running fine — SIGKILL-bound.
//
// Info.plist damage is NOT in that category and is deliberately still fatal:
// CFBundleIdentifier feeds the designated requirement itself, so a plist
// that no longer matches its seal really does break the grant. What round 5
// got wrong there was the WORDS, not the verdict — see below.
let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
let sealStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, nil)

/// Apple's own description of an OSStatus. Never this file's paraphrase.
func describe(_ status: OSStatus) -> String {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
    return "\(text) (OSStatus \(status))"
}

/// True when `target` is a path this project installs to, and therefore one
/// the caller may safely be told to delete and reinstall. README documents
/// running this against ANY path, so a third-party application must never be
/// handed a destructive prescription — round 5 told the user to `rm -f` the
/// executable of a working copy of Anki.
let isOurInstall: Bool = {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let canonical = URL(fileURLWithPath: target).standardizedFileURL.path
    return canonical == home + "/bin/safari-browser"
        || canonical.hasPrefix(home + "/bin/safari-browser.")   // mktemp staging
}()

if sealStatus != errSecSuccess {
    if sealStatus == errSecCSUnsigned {
        err("✗ no code signature: \(target)")
        err("  An unsigned binary cannot hold a Full Disk Access grant.")
        exit(2)
    }

    let sealItself = [errSecCSSignatureFailed,
                      errSecCSSignatureInvalid,
                      errSecCSSignatureNotVerifiable].contains(sealStatus)

    err("✗ signature does not validate: \(target)")
    err("  \(describe(sealStatus))")
    err("")
    if sealItself {
        err("  The signature no longer covers the bytes, so macOS refuses to run")
        err("  this binary — SIGKILL, exit 137, no readable error.")
    } else {
        err("  The code seal itself may be intact, but part of what it covers no")
        err("  longer matches. Either way the code does not validate, so TCC will")
        err("  not honour a Full Disk Access grant on it.")
    }
    err("")
    if isOurInstall {
        err("  Fix:  rm -f \"\(target)\" && DEVELOPER_ID=<cert-sha1> make install-signed")
    } else {
        err("  This is not a path this project installs, so no fix is offered here:")
        err("  re-installing or re-signing someone else's software is their call,")
        err("  and deleting it on this tool's say-so would be worse than the fault.")
    }
    exit(3)
}

// ── 3. Ad-hoc? A flag bit, not a field parsed out of a diagnostic. ───────
var infoRef: CFDictionary?
guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        == errSecSuccess,
      let info = infoRef as? [String: Any] else {
    envProblem("could not read the signing information of \(target)")
}

if let want = requiredEntitlement {
    let ents = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    guard let ents, ents[want] != nil else {
        err("✗ required entitlement missing: \(want)")
        err("  \(target)")
        err("  The signature carries \(ents?.count ?? 0) entitlement(s); this is read from")
        err("  the signature itself, not from codesign's printed output.")
        exit(4)
    }
}

let adhocBit: UInt32 = 0x0002  // kSecCodeSignatureAdhoc
let signFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
if signFlags & adhocBit != 0 {
    err("✗ ad-hoc signature: \(target)")
    if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
        err("  TeamIdentifier=\(team)")
    }
    err("")
    err("  An ad-hoc signature has no certificate behind it, so its designated")
    err("  requirement is the binary's own content hash. A rebuild changes the")
    err("  hash, and any Full Disk Access grant stops applying — silently.")
    err("")
    err("  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed")
    exit(1)
}

// ── 4. The designated requirement, as an object ──────────────────────────
// Exactly one. No path in it, no sibling lines, nothing to forge.
var reqRef: SecRequirement?
guard SecCodeCopyDesignatedRequirement(staticCode, [], &reqRef) == errSecSuccess,
      let requirement = reqRef else {
    envProblem("could not read the designated requirement of \(target)")
}

var textRef: CFString?
guard SecRequirementCopyString(requirement, [], &textRef) == errSecSuccess,
      let drText = textRef as String? else {
    envProblem("could not render the designated requirement of \(target)")
}

// ── 5. Is it a shape we recognise? ───────────────────────────────────────
// Whole-string anchored. Quoted strings are opaque groups that understand
// backslash escapes, so an embedded quote cannot end the group early and a
// string's CONTENTS can never be read as structure. This text came from the
// requirement object, so there is no second requirement it could describe.
let ident = #"identifier ("([^"\\]|\\.)*"|[A-Za-z0-9_.\-]+)"#
let str = #"("([^"\\]|\\.)*"|[A-Za-z0-9_.\-]+)"#
let devIDOIDs = #"certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.6\] /\* exists \*/ and certificate leaf\[field\.1\.2\.840\.113635\.100\.6\.1\.13\] /\* exists \*/"#

let shapes: [(String, String)] = [
    // What `install-signed` produces: Developer ID with hardened runtime.
    ("Developer ID",
     #"^\#(ident) and anchor apple generic and \#(devIDOIDs) and certificate leaf\[subject\.OU\] = \#(str)$"#),
    // What Apple's own binaries carry (/bin/ls and friends).
    ("Apple system",
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

guard let matchedShape = shape else {
    err("✗ cannot tell whether this grant is durable: \(target)")
    err("  DR: \(drText)")
    err("")
    err("  This tool recognises the requirement shapes a standard codesign")
    err("  invocation produces, and this is not one of them. It does not try")
    err("  to interpret arbitrary requirements: five rounds of review showed")
    err("  that reading them as text gets the answer wrong in both directions,")
    err("  so the honest answer here is that it does not know.")
    err("")
    err("  Inspect it yourself:  codesign -d -r- \"\(target)\"")
    err("  Or reinstall onto known ground:  DEVELOPER_ID=<cert-sha1> make install-signed")
    exit(5)
}

// ── 6. Does this binary actually satisfy it? ─────────────────────────────
// The requirement OBJECT goes back to the API. It is never serialised and
// re-parsed, so the requirement checked is necessarily the one read — the
// round-5 defect where whitespace normalisation rewrote a certificate CN
// before re-parsing it cannot occur here.
let satisfies = SecStaticCodeCheckValidity(staticCode, checkFlags, requirement)
if satisfies != errSecSuccess {
    err("✗ does not satisfy its own designated requirement: \(target)")
    err("  DR: \(drText)")
    err("  \(describe(satisfies))")
    err("")
    err("  The seal is intact and the requirement is a durable shape, but this")
    err("  binary cannot satisfy it — usually a signature made with one")
    err("  identity while carrying another's requirement. TCC records the")
    err("  requirement when you grant access, so the grant would never apply.")
    err("")
    err("  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed")
    exit(4)
}

if let want = requiredShape, matchedShape != want {
    err("✗ wrong signing identity: \(target)")
    err("  required shape: \(want)")
    err("  actual shape:   \(matchedShape)")
    err("  DR: \(drText)")
    err("")
    err("  `security find-identity -v -p codesigning` often lists an Apple")
    err("  Development identity FIRST; install-signed needs the Developer ID one.")
    exit(4)
}

out("✓ durable: \(matchedShape) requirement, valid seal, and this binary satisfies it")
out("  \(target)")
out("  \(drText)")
out("  A Full Disk Access grant on this binary survives rebuilds.")
