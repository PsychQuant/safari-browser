#!/usr/bin/env swift
// Will a Full Disk Access grant on this binary still apply later? (#119)
//
// TCC stores the binary's designated requirement (DR) and re-evaluates it, so
// the grant is durable exactly when the DR names an identity the binary keeps
// across rebuilds — rather than its bytes, which change every build.
//
// Verdicts about the binary — 0-7, and nothing else in this range:
//
//   0  durable: a recognised identity-bound shape, and the binary satisfies it
//   1  ad-hoc signature — the DR is the content hash, so a rebuild kills it
//   2  no code signature at all
//   3  the signature does not validate — TCC will not honour a grant on it
//   4  recognised shape, but this binary cannot satisfy it — grant never applies
//   5  a requirement shape this tool does not recognise — it cannot tell
//   6  --require-shape given, and the shape is a different (durable) one
//   7  --require-entitlement given, and the signature does not carry it
//
// NOT verdicts — deliberately outside that range, so a caller can tell a
// statement about the binary from a failure to make one (sysexits.h):
//
//  64  usage error — bad flags. Nothing was inspected.
//  70  the check could not run: unreadable file, API failure, no HOME.
//
// Round 6 found three separate collisions in the older numbering. `2` meant
// both "this binary is unsigned" (a verdict) and "the check could not run"
// (not one). A missing flag value hit `fatalError`, which the shebang form
// turned into exit 5 — "unrecognised shape, inspect it yourself" — for a
// binary that was never opened. And `--require-shape` mismatch and a missing
// entitlement both returned 4, whose documented meaning is that the binary
// cannot satisfy its OWN requirement — which in both cases it can.
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
// greps are gone FROM THIS FILE, and both answers here come from the
// signature itself.
//
// That qualification is load-bearing, and round 7 is why. The sentence used to
// end at "are gone", which is false about the product: CodeSigningState.parse
// still classifies a signature with unanchored `contains()` over the stderr of
// `codesign -dvv <path>` — the same stream codesign writes the path into. Put
// an UNSIGNED file inside a directory named `Authority=Developer ID
// Application` and the shipped classifier calls it .developerID, whose guidance
// text does not mention that a rebuild invalidates the grant. That is round
// five's "two byte-identical copies, opposite verdicts", still live in
// Sources/, and it is tracked as #122.
//
// The deeper fault is not that bug. It is that this file became a second
// source of truth for "is this signature durable" without the first one being
// retired. Two answers to one question, one reading OSStatus and SecRequirement
// objects and one reading English prose, is the defect — #122 is where they
// get merged, and until then no comment in this repo may claim the greps are
// gone without saying which ones.
var requiredShape: String?
var requiredEntitlement: String?
var positional: [String] = []
var rest = Array(CommandLine.arguments.dropFirst())

/// Usage errors exit 64, never a verdict code. Round 6: `--require-shape`
/// with no value reached `fatalError`, and under the shebang form that
/// surfaced as exit 5 — a documented verdict ("cannot tell, inspect it
/// yourself") about a binary this process never opened.
func usage(_ problem: String) -> Never {
    FileHandle.standardError.write(("""
    ✗ \(problem)

      usage: verify-install-signature.swift [--require-shape NAME]
                                            [--require-entitlement KEY] [path]

      Exits 0-7 with a verdict about the binary; 64 for a usage error like this
      one, 70 when the check could not run. Nothing was inspected.

    """ + "\n").data(using: .utf8)!)
    exit(64)
}

/// Takes an option's value, refusing three things the hand-rolled loop got
/// wrong twice. Round 6 fixed only "the value is missing from the end of
/// argv"; round 7 found the other two still open, and both disarm the gate
/// that is the entire point of these flags:
///
///   * a value that is itself an option — `--require-shape --require-entitlement
///     /bin/ls` consumed the second flag as the first one's value and returned
///     a verdict about a binary the caller never named;
///   * a repeat — `--require-shape "Developer ID" /bin/ls --require-shape
///     "Apple system"` silently overrode the first and exited 0.
///
/// A gate that a later argument can switch off is not a gate. Neither was one
/// a typo could switch off, which is what round 6 said while leaving these.
func takeValue(_ flag: String, into slot: inout String?) {
    if slot != nil { usage("\(flag) given more than once") }
    guard let v = rest.first else { usage("\(flag) needs a value") }
    if v.hasPrefix("-") { usage("\(flag) needs a value, got the option \(v)") }
    slot = v; rest.removeFirst()
}

while let head = rest.first {
    rest.removeFirst()
    switch head {
    case "--require-shape":
        takeValue(head, into: &requiredShape)
    case "--require-entitlement":
        takeValue(head, into: &requiredEntitlement)
    case let f where f.hasPrefix("-"):
        // Round 6: unknown flags fell through to `positional`, and every
        // positional after the first was dropped. So `verify <path>
        // --require-shapee X` — one typo — silently ran with no gate at all
        // and exited 0.
        usage("unknown option: \(f)")
    default:
        positional.append(head)
    }
}

if positional.count > 1 {
    usage("expected at most one path, got \(positional.count): \(positional.joined(separator: " "))")
}

guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
    FileHandle.standardError.write("✗ HOME is unset — cannot resolve the default target.\n".data(using: .utf8)!)
    exit(70)
}
let target = positional.first ?? home + "/bin/safari-browser"

/// POSIX single-quoting, for any path this tool puts inside a command it
/// expects a human to run. Round 6: the path was interpolated into
/// `rm -f "\(display(target))"`, and double quotes do not disable `$(...)` — so a
/// filename could smuggle a command into a destructive line the tool itself
/// told the user to paste. That is round 5's defect exactly, one channel over:
/// the requirement stopped being text, the path never did.
/// Escapes control characters for display. Round 7: the path was sh()-quoted
/// inside the commands this tool prints, and printed RAW everywhere else — so
/// a filename containing a newline emitted a line reading, byte for byte,
/// "✓ durable: Developer ID requirement, valid seal, and this binary satisfies
/// it" while the verdict above it said the binary was unsigned. Round 5's
/// forged-line attack, a third channel over: first the requirement, then the
/// command, now the diagnostic itself.
func display(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u {
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20 || c.value == 0x7f:
            out += String(format: "\\x%02x", c.value)
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

/// True when the path carries anything that would let it forge output or
/// smuggle structure into a printed command. Such a path gets its escaped form
/// and no paste-ready command: a command containing a literal newline is not
/// paste-ready anyway, and printing one invites exactly the confusion above.
let targetIsPrintable = target.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }

func sh(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func envProblem(_ what: String) -> Never {
    err("✗ \(what)")
    err("  This is an environment problem, not a verdict about \(display(target)).")
    exit(70)
}

// ── 1. Get a handle on the code ──────────────────────────────────────────
var code: SecStaticCode?
let url = URL(fileURLWithPath: target) as CFURL
let createStatus = SecStaticCodeCreateWithPath(url, [], &code)

if createStatus != errSecSuccess {
    if !FileManager.default.fileExists(atPath: target) {
        err("✗ no such file: \(display(target))")
        exit(70)
    }
    if createStatus == errSecCSUnsigned {
        err("✗ no code signature: \(display(target))")
        err("  An unsigned binary cannot hold a Full Disk Access grant.")
        exit(2)
    }
    envProblem("could not read \(display(target)) as code (OSStatus \(createStatus))")
}
guard let staticCode = code else {
    envProblem("could not read \(display(target)) as code")
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
    let canonical = URL(fileURLWithPath: target).standardizedFileURL.path
    let installed = home + "/bin/safari-browser"
    if canonical == installed { return true }
    // The staging file `install-signed` verifies before landing. Round 6:
    // this was a bare `hasPrefix(installed + ".")`, which any suffix
    // satisfied — so `~/bin/safari-browser.$(...)` was treated as ours and
    // handed the destructive prescription. The check that existed to keep
    // `rm -f` away from other people's software was the thing that let it
    // through. Now it demands mktemp's actual shape: exactly six characters
    // from its alphabet, and nothing else.
    guard canonical.hasPrefix(installed + ".") else { return false }
    let suffix = canonical.dropFirst(installed.count + 1)
    return suffix.count == 6 && suffix.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII }
}()

if sealStatus != errSecSuccess {
    if sealStatus == errSecCSUnsigned {
        err("✗ no code signature: \(display(target))")
        err("  An unsigned binary cannot hold a Full Disk Access grant.")
        exit(2)
    }

    let sealItself = [errSecCSSignatureFailed,
                      errSecCSSignatureInvalid,
                      errSecCSSignatureNotVerifiable].contains(sealStatus)

    err("✗ signature does not validate: \(display(target))")
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
        if targetIsPrintable {
            err("  Fix:  rm -f \(sh(target)) && DEVELOPER_ID=<cert-sha1> make install-signed")
        } else {
            err("  This path contains control characters, so no paste-ready command is")
            err("  offered. Remove it by whatever means you are sure of, then:")
            err("        DEVELOPER_ID=<cert-sha1> make install-signed")
        }
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
    envProblem("could not read the signing information of \(display(target))")
}

let adhocBit: UInt32 = 0x0002  // kSecCodeSignatureAdhoc
let signFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
if signFlags & adhocBit != 0 {
    err("✗ ad-hoc signature: \(display(target))")
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

// The entitlement gate runs HERE, after the ad-hoc verdict. Round 7: it ran
// before, so an ad-hoc binary was answered 7 — "install-signed's contract" —
// when the honest answer is 1, and the message explained the wrong fault.
if let want = requiredEntitlement {
    let ents = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    // Present is not the same as granted. Round 7 signed a Developer ID
    // binary whose apple-events entitlement was explicitly <false/> and this
    // gate passed it — install-signed would have shipped a signature that
    // spells out that it does NOT have the permission.
    let granted: Bool = {
        guard let v = ents?[want] else { return false }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return true   // a non-boolean entitlement (a string, an array) is a value, not a denial
    }()
    if !granted {
        err("✗ required entitlement not granted: \(want)")
        err("  \(display(target))")
        if ents?[want] == nil {
            err("  The signature does not carry it at all.")
        } else {
            err("  The signature carries it, set to a value that denies it.")
        }
        err("  Read from the signature itself, not from codesign's printed output.")
        err("")
        err("  This is install-signed's own contract, not a fault in the binary's")
        err("  designated requirement — hence 7 rather than 4.")
        exit(7)
    }
}

// ── 4. The designated requirement, as an object ──────────────────────────
// Exactly one. No path in it, no sibling lines, nothing to forge.
var reqRef: SecRequirement?
guard SecCodeCopyDesignatedRequirement(staticCode, [], &reqRef) == errSecSuccess,
      let requirement = reqRef else {
    envProblem("could not read the designated requirement of \(display(target))")
}

var textRef: CFString?
guard SecRequirementCopyString(requirement, [], &textRef) == errSecSuccess,
      let drText = textRef as String? else {
    envProblem("could not render the designated requirement of \(display(target))")
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
    err("✗ cannot tell whether this grant is durable: \(display(target))")
    err("  DR: \(drText)")
    err("")
    err("  This tool recognises the requirement shapes a standard codesign")
    err("  invocation produces, and this is not one of them. It does not try")
    err("  to interpret arbitrary requirements: five rounds of review showed")
    err("  that reading them as text gets the answer wrong in both directions,")
    err("  so the honest answer here is that it does not know.")
    err("")
    if targetIsPrintable {
        err("  Inspect it yourself:  codesign -d -r- \(sh(target))")
    } else {
        err("  This path contains control characters; no paste-ready command is offered.")
    }
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
    err("✗ does not satisfy its own designated requirement: \(display(target))")
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
    err("✗ wrong signing identity: \(display(target))")
    err("  required shape: \(want)")
    err("  actual shape:   \(matchedShape)")
    err("  DR: \(drText)")
    err("")
    err("")
    err("  Both shapes are durable; this one is simply not the one asked for.")
    err("  That is install-signed's contract, not a fault in the binary — hence 6")
    err("  rather than 4, whose documented meaning is that a binary cannot satisfy")
    err("  its OWN requirement. `security find-identity -v -p codesigning` often")
    err("  lists an Apple Development identity FIRST; install-signed needs the")
    err("  Developer ID one.")
    exit(6)
}

out("✓ durable: \(matchedShape) requirement, valid seal, and this binary satisfies it")
out("  \(display(target))")
out("  \(drText)")
out("  A Full Disk Access grant on this binary survives rebuilds.")
