#!/bin/sh
//usr/bin/env true; guard_builder="$(dirname "$0")/build-signature-guard.py"; if [ ! -r "$guard_builder" ]; then printf '%s\n' 'Cannot build signature guard: helper unavailable' >&2; exit 70; fi; exec /usr/bin/env python3 "$guard_builder" --run -- "$@"
// The line above is a Swift comment and a shell bootstrap: direct execution
// uses the shared build helper, while emitted Swift source ignores it.
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
// Round 7 found a second classifier in CodeSigningState.parse: a directory
// named Authority=Developer ID Application could make unsigned bytes look
// durable. #122 removed that parser. Runtime and guard now both consume
// SignatureAssessment's Security-framework verdict; this wrapper only renders
// messages and maps them to the documented exit codes.
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

      Exit codes are defined once, in the header comment of this file. This
      message is a usage error: nothing was inspected.

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
    // @mutant(usage-repeat-flag) slot != nil => false
    //   R7. Reverting lets a later repeat silently override the first, so a
    //   gate can be switched off by an argument appended after the path.
    if slot != nil { usage("\(display(flag)) given more than once") }
    guard let v = rest.first else { usage("\(display(flag)) needs a value") }
    // @mutant(usage-option-as-value) v.hasPrefix("-") => false
    //   R7. Reverting consumes the NEXT OPTION as this flag's value, so the
    //   tool delivers a verdict about a binary the caller never named.
    if v.hasPrefix("-") { usage("\(display(flag)) needs a value, got the option \(display(v))") }
    // Round 8: `--require-shape /bin/ls` took the path as the shape name and
    // then delivered a verdict about the DEFAULT target — a binary the caller
    // never named, reported as "wrong signing identity". Round 7 rejected a
    // value that looked like an option and stopped there; this is the same
    // class one shape over.
    // @mutant(usage-path-as-name) v.hasPrefix("/") || v.hasPrefix("./") || v.hasPrefix("~/") => false
    //   R8. Reverting takes a path as the shape NAME and then reports on the
    //   DEFAULT target — again a binary the caller never named.
    if v.hasPrefix("/") || v.hasPrefix("./") || v.hasPrefix("~/") {
        usage("\(display(flag)) needs a name, got what looks like a path: \(display(v))")
    }
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
        // @mutant(usage-unknown-option) usage("unknown option: \(display(f))") => positional.append(f)
        //   R6. Reverting sends an unrecognised flag to the positional list,
        //   so one typo runs with no gate at all and exits 0.
        usage("unknown option: \(display(f))")
    default:
        positional.append(head)
    }
}

// @mutant(usage-extra-path) positional.count > 1 => false
//   R6. Reverting drops every path after the first, so a second path is
//   silently ignored rather than refused.
if positional.count > 1 {
    usage("expected at most one path, got \(positional.count): \(positional.map(display).joined(separator: " "))")
}

guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
    FileHandle.standardError.write("✗ HOME is unset — cannot resolve the default target.\n".data(using: .utf8)!)
    exit(70)
}
let target = positional.first ?? home + "/bin/safari-browser"

// ── Mutation declarations (@mutant) ──────────────────────────────────────
//
// Tests/mutation-gate.sh reverts each declared fix and requires the suite to
// go red on a NAMED assertion. Round 9 of #119 is why: the suite had 35 green
// assertions and, measured by reverting fixes one at a time, could not tell
// three of them from the original. Assertions were added for the instance each
// round had just fixed; nothing ever asked whether they discriminated.
//
// Format, on the line directly above the code it protects:
//
//     // @mutant(<id>) <from> => <to>
//     //   prose: which round, and what the revert lets through
//
// The target is the first following line that is neither blank nor a comment,
// and <from> must occur exactly once in it. That is the whole point of
// anchoring the declaration to the source rather than listing mutants in the
// gate: a refactor that moves the code carries its declaration along, and one
// that deletes the text makes the gate ERROR ("site no longer contains
// <from>") instead of quietly having nothing to revert. Rounds 7 and 8 were
// both lost to a hand-maintained second copy of a fact that lived in this
// file — `^[0-5]$` and a hardcoded count of 10 — and a list of mutants kept
// somewhere else is that same object.
//
// What this does NOT establish: that every fix has a declaration. A fix can be
// one character, and no extraction can tell a line that closes a review
// finding from any other line. The gate enforces that declared mutants die;
// declaring them is a review obligation, stated here and in the suite header.

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
        case let c where !isSafeToPrint(c):
            out += String(format: "\\u{%04x}", c.value)
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

/// Round 8: `display()` and the printable test both covered only C0 and DEL.
/// Everything below is also a way to move the cursor, start a new line, or
/// reverse the reading order of what follows — i.e. to make output say
/// something other than what this tool wrote.
func isSafeToPrint(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x00...0x1f, 0x7f:            return false   // C0 + DEL
    // @mutant(safe-print-c1) return false => return true
    //   R8. Reverting narrows the printable test back to C0 and DEL, so
    //   U+0085 (NEL) starts a new line in output that is not this tool's.
    case 0x80...0x9f:                  return false   // C1, incl. NEL (U+0085)
    case 0x2028, 0x2029:               return false   // line / paragraph separator
    case 0x200e, 0x200f:               return false   // LRM / RLM
    // @mutant(safe-print-bidi) return false => return true
    //   R8. Reverting lets a bidi override reverse the reading order of
    //   everything after it, so printed text can say the opposite of itself.
    case 0x202a...0x202e:              return false   // bidi embedding + override
    case 0x2066...0x2069:              return false   // bidi isolates
    case 0x200b...0x200d, 0x2060:      return false   // zero-width
    case 0xfeff:                       return false   // BOM / ZWNBSP
    default:                           return true
    }
}

/// True when the path carries anything that would let it forge output or
/// smuggle structure into a printed command. Such a path gets its escaped form
/// and no paste-ready command: a command containing a literal newline is not
/// paste-ready anyway, and printing one invites exactly the confusion above.
// @mutant(printable-always) target.unicodeScalars.allSatisfy(isSafeToPrint) => true
//   R7 CRITICAL. Reverting offers a paste-ready command for a path containing
//   a newline, which emits a line reading byte for byte like this tool's own
//   success message directly under a failing verdict.
let targetIsPrintable = target.unicodeScalars.allSatisfy(isSafeToPrint)

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
    // @mutant(our-install-noncanonical-home) URL(fileURLWithPath: home + "/bin/safari-browser").standardizedFileURL.path => home + "/bin/safari-browser"
    //   R10. Only `canonical` was standardized, so a HOME spelled any other way
    //   that denotes the same directory — a trailing slash, a doubled slash, a
    //   `.` component — made the real install path compare unequal to itself.
    //   The binary that IS ours was then refused the one prescription that
    //   applies to it, which is the R5 defect pointing the other way.
    let installed = URL(fileURLWithPath: home + "/bin/safari-browser").standardizedFileURL.path
    // @mutant(our-install-any-path) canonical == installed => true
    //   R5 CRITICAL. Reverting makes every path "ours", so a third-party
    //   binary with a broken seal is handed `rm -f` — review measured this
    //   against a working copy of Anki.
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
    // @mutant(our-install-loose-suffix) suffix.count == 6 && suffix.allSatisfy => true || suffix.allSatisfy
    //   R6. Reverting accepts any suffix after the dot, so
    //   `~/bin/safari-browser.$(...)` counts as ours and gets the destructive
    //   prescription — the check meant to keep `rm -f` away from other
    //   people's software was itself the hole.
    return suffix.count == 6 && suffix.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII }
}()

// Classification is shared with CodeSigningState; only rendering is local.
let assessment = SignatureAssessment.evaluate(at: URL(fileURLWithPath: target), requiredEntitlement: requiredEntitlement)
switch assessment {
case .missingFile:
    err("✗ no such file: \(display(target))")
    exit(70)
case .unavailable(let operation, let status):
    let detail = status.map { " (OSStatus \($0))" } ?? ""
    envProblem("could not \(operation) of \(display(target))\(detail)")
case .unsigned:
    err("✗ no code signature: \(display(target))")
    err("  An unsigned binary cannot hold a Full Disk Access grant.")
    exit(2)
case .invalidSeal(let sealStatus):
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
case .adHoc(let team):
    err("✗ ad-hoc signature: \(display(target))")
    if let team {
        err("  TeamIdentifier=\(team)")
    }
    err("")
    err("  An ad-hoc signature has no certificate behind it, so its designated")
    err("  requirement is the binary's own content hash. A rebuild changes the")
    err("  hash, and any Full Disk Access grant stops applying — silently.")
    err("")
    err("  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed")
    exit(1)
case .missingEntitlement(let want, let present):
    err("✗ required entitlement not granted: \(display(want))")
    err("  \(display(target))")
    if !present {
        err("  The signature does not carry it at all.")
    } else {
        err("  The signature carries it, but not as a boolean true.")
    }
    err("  Read from the signature itself, not from codesign's printed output.")
    err("")
    err("  This is install-signed's own contract, not a fault in the binary's")
    err("  designated requirement — hence 7 rather than 4.")
    exit(7)
case .unknownRequirement(let drText):
    err("✗ cannot tell whether this grant is durable: \(display(target))")
    err("  DR: \(display(drText))")
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
case .unsatisfiedRequirement(let drText, let satisfies):
    err("✗ does not satisfy its own designated requirement: \(display(target))")
    err("  DR: \(display(drText))")
    err("  \(describe(satisfies))")
    err("")
    err("  The seal is intact and the requirement is a durable shape, but this")
    err("  binary cannot satisfy it — usually a signature made with one")
    err("  identity while carrying another's requirement. TCC records the")
    err("  requirement when you grant access, so the grant would never apply.")
    err("")
    err("  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed")
    exit(4)
case .durable(let matchedShape, let drText):
    // @mutant(shape-mismatch-open) matchedShape != want => false
    //   R6. Reverting drops --require-shape's verdict, so install-signed would
    //   land a binary signed by the wrong identity and report success.
    if let want = requiredShape, matchedShape != want {
        err("✗ wrong signing identity: \(display(target))")
        err("  required shape: \(display(want))")
        err("  actual shape:   \(display(matchedShape))")
        err("  DR: \(display(drText))")
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
    out("  \(display(drText))")
    out("  A Full Disk Access grant survives rebuilds while the signing identity and designated requirement stay the same.")

}
