# Cutting a release

For the maintainer. It describes how a binary for other people is made; running from
source needs none of it (`make install`, or `make install-signed` for a Full Disk Access
grant that survives rebuilds).

The release binary is **Universal** (arm64 and x86_64), signed with a **Developer ID**
and the hardened runtime plus a secure timestamp, and — when you ask for it — accepted
by Apple's notary service. `--version` on it prints the tag it was built from (#278).

## What `make release-signed` does, and what it leaves to you

| Does | Never does |
|---|---|
| Refuses early: `DEVELOPER_ID` not the 40-hex SHA-1 of a valid *Developer ID Application* certificate in the keychain, tree not clean (untracked files count, and so do untracked files under `Sources/` that git ignores, because SwiftPM compiles them), `HEAD` without exactly one tag matching `v[0-9]*` (which must then have the `vX.Y.Z` shape), notary profile not answering | Create or push a tag |
| Builds both architectures from that commit, stamping the tag into the binary | Call `gh`, or publish anything |
| Signs, then verifies: `codesign --verify`, the install-signature guard (`#119`), and that the binary reports the tag | Submit anything for notarization unless `NOTARIZE=1` (signing still asks Apple's *timestamp* server for a timestamp, see below) |
| With `NOTARIZE=1`: submits and waits; only `Accepted` passes, anything else prints the failure (and Apple's log when the answer carried a submission id) and fails. An accepted submission's id is printed at once, so it survives a failure later in the run | Leave a half-built `dist/` behind when it fails or is stopped with Ctrl-C: the output name is reserved first and the result is staged and moved in last. (A SIGKILL or a power cut is the exception: it can leave a `dist/.staging.*` directory, which holds a signed binary, and the reserved, empty output directory; remove both by hand. A directory the cleanup cannot remove is reported.) |
| Writes `dist/<tag>/` and prints the commands for you to run | |

`release.sh` runs from the commit being released, so before you tag, review what changed
in it since the last release:
`git diff <previous-tag>..<commit> -- scripts Makefile Package.swift 'Sources/SafariBrowser/*.plist' Sources/SafariBrowser/Utilities/SignatureAssessment.swift`
(the last one is compiled into the install-signature guard).

## One-time setup

1. A **Developer ID Application** certificate in the login keychain. Its SHA-1 is the
   `DEVELOPER_ID` below: `security find-identity -v -p codesigning`.
2. A notary profile, so that no password is ever on a command line or in a file:

   ```bash
   xcrun notarytool store-credentials che-mcps-notary
   ```

   `notarytool` asks for the Apple ID, team and an app-specific password. Type them
   yourself at its prompt; do not paste the password anywhere else. Another name is fine:
   pass it as `NOTARY_PROFILE=<name>`. Check that it works:

   ```bash
   xcrun notarytool history --keychain-profile che-mcps-notary
   ```

## Making a release

Build from a clean checkout of the commit you mean to release: the script refuses a
tree with any uncommitted or untracked file, and one whose tracked files under `Sources/`
are marked skip-worktree or assume-unchanged (git status cannot see edits to those). Do not edit, commit or switch branches in
that checkout while it runs (the build takes minutes; #309 tracks making that safe).

Before tagging, make the commit describe the release: in `README.md`, the install
section's "none has been published yet" line and the version it names; in `CHANGELOG.md`,
the `## Unreleased` heading becomes the version. The tag is cut from that commit.

The version and the commit are your decision. The commit must carry exactly ONE tag
matching `v[0-9]*`: with several, git would pick one for you, so the script refuses.
The first `make` line is the rehearsal (nothing is submitted for notarization), the
second the real one (it goes to Apple). The lines carry no trailing comments, so they
can be pasted into zsh as they are:

```bash
git tag v2.7.0 <commit>
DEVELOPER_ID=<sha1> make release-signed
DEVELOPER_ID=<sha1> NOTARIZE=1 make release-signed
```

Tags may carry a prerelease part (`v2.7.0-rc.1`); the printed `gh` line then adds
`--prerelease`. A tag ending in `-DRYRUN` is refused (it would collide with the
rehearsal's directory name).

The rehearsal signs for real. Signing with `--timestamp` asks Apple's timestamp server
for a timestamp, which sends it the signature's hash, so a rehearsal is not fully
offline, but nothing is submitted for notarization and the binary never goes to Apple's
notary service. It writes `dist/<tag>-DRYRUN/` with a `DRYRUN-NOT-NOTARIZED` marker file
next to the binary: that marks it for you, but the binary itself is a valid Developer ID
binary that reports the release tag, so do not upload it. To leave the timestamp request
out too, add `RELEASE_TIMESTAMP=none`; it is refused together with `NOTARIZE=1`. That
takes Apple's timestamp server and notary service out of the run. Whether macOS checks
certificates online while signing, or when the signed binary first runs, has not been
measured, so even that run is not called offline. (A fresh clone also needs the network
once for SwiftPM to resolve packages.) The
rehearsal also builds the submission zip, so a `ditto` or `TMPDIR` problem shows up
before the real run.

`dist/<tag>/` holds:

| File | Content |
|---|---|
| `safari-browser` | the signed Universal binary |
| `safari-browser.sha256` | the SHA-256 and nothing else (one line) |
| `NOTARIZATION.json` | notarytool's JSON answer: submission id, message and status (no date) |

On success the script prints the commands below, each followed by what it must show.
Running them is yours: the push and the release are visible to everyone and cannot be
taken back.

```bash
git push origin v2.7.0
git ls-remote origin 'refs/tags/v2.7.0' 'refs/tags/v2.7.0^{}'
shasum -a 256 dist/v2.7.0/safari-browser
gh release create v2.7.0 --verify-tag [--prerelease] --repo <owner>/<name> dist/v2.7.0/safari-browser dist/v2.7.0/safari-browser.sha256 --title v2.7.0 --notes '…team <TEAM_ID>…'
```

For an annotated tag, `ls-remote` shows the tag object on the `refs/tags/<tag>` line and the
commit on the `refs/tags/<tag>^{}` line; for a lightweight tag there is only the first line.
`shasum` checks, just before the upload, that the file is still the one the run produced.
`--repo` is the repository `origin` points at, so the push and the release go to the same
place; when `origin` is not a github.com remote the line leaves it out and says so. The
release notes name the signing team ID (see the next section for what that does and does
not prove).

The `ls-remote` check and `--verify-tag` are there because `gh release create` creates a
tag that is missing from the remote *at the tip of the default branch*, not at the
commit that was built. If the push was skipped or rejected, the public tag would name a
different commit than the one the binary reports.

## When Apple says no

The script prints the status and notarytool's answer, then, when the answer carried a
submission id, the output of `xcrun notarytool log <id>`; it exits non-zero with nothing
left in `dist/`. If no id could be read it says so and tells you to find the submission
with `notarytool history`. Typical causes: a signature without a secure timestamp (this
target always asks for one, unless `RELEASE_TIMESTAMP=none`, which is refused with
`NOTARIZE=1`), a certificate that is not a Developer ID Application one, or an
entitlement problem. The difference from `install-signed` is the timestamp: both sign
with the hardened runtime.

## Checking a downloaded copy

The checksum travels through the same channel as the binary, so it catches a damaged
download, not a swapped one. The signature requirement below pins the file to a
*Developer ID Application* certificate of one team. It is only as good as the team ID
you compare against: the release notes name it, but the notes travel with the binary too, so whoever could swap the file
could change them as well. Compare the team ID with one you got some other way (an
earlier release you checked, or the maintainer). Run the checks before you run the file:

```bash
test "$(shasum -a 256 < safari-browser | awk '{print $1}')" = "$(cat safari-browser.sha256)" \
  && chmod +x safari-browser \
  && codesign --verify --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "<TEAM_ID>"' safari-browser \
  && ./safari-browser --version
```

Run it in the folder you downloaded to, with `<TEAM_ID>` replaced (for the maintainer: the
10-character code in parentheses in the certificate's name). `codesign --verify` on its
own accepts any valid signature (an ad-hoc local build included); the `-R=` requirement is
what pins it. Its two `certificate … exists` parts are the markers of a Developer ID
certificate: without them, an *Apple Development* certificate of the same team would pass
too. (Measured 2026-10-27: the requirement parses, passes on a Developer ID binary signed
by the team it names, and fails with another team or on an Apple-signed system binary.)
Running `safari-browser --version` without `./` would run whatever is first on your
`PATH`, not the download.

**Notarization cannot be confirmed from the command line for this binary.** A release is a
bare Mach-O, and Apple's ticket cannot be stapled to one (`stapler staple` fails with
error 73). Without a stapled ticket the local tools answer "not notarized" even for a
notarized release. Measured 2026-10-28 on v2.7.0, whose notarization was `Accepted` with a
ticket listing both slices' cdhashes: `spctl --assess --type execute` said
`rejected, source=Unnotarized Developer ID`, also with `--ignore-cache` and after asking
Apple (`assessment:remote` true); `syspolicy_check distribution` reported the ticket
missing; `codesign --check-notarization -R=notarized` failed. That is why `spctl` is not
in the check above. When a copy downloaded through a browser (and so quarantined) first
runs, Gatekeeper is expected to look the ticket up online; that has not been observed. A
copy fetched with `curl` or `gh` carries no quarantine flag, and Gatekeeper does not check
it at all.

## Updating with `self-update` (#314)

From the first release that contains it, an installed release updates itself with
`safari-browser self-update` (`--check` only reports). It performs the checks above
without a team ID typed by hand: the new binary must satisfy the **installed binary's
designated requirement** (identifier, Developer ID certificate chain and team), carry the
hardened runtime and the Apple Events entitlement, match `safari-browser.sha256`, and print
the release tag; only then is it renamed over the installed one, with the old kept as
`<binary>.previous`. So the asset names and the `.sha256` format this script writes are a
contract: `SelfUpdateReleaseContractTests` reads `BINARY_NAME` from `scripts/release.sh`
and fails when the two drift apart. Notarization is not checked, for the reason above.

## Stopping a run

Ctrl-C at the terminal stops the build or the notarization wait too, because it reaches
the whole process group; the cleanup then removes everything the run made. A signal sent
only to `release.sh` (with `kill`, say) takes effect when the build step or the
notarization wait that is running returns, which can be minutes. A signal that arrives
while the finished result is being moved into `dist/<tag>/` is honoured right after the
move, and the result is kept.

## Measured, and not measured

A rehearsal (`NOTARIZE=0`, a real Developer ID, a clean clone on a throwaway tag) on
2026-10-25 gave a 14.9 MB Universal binary (`lipo -archs`: `x86_64 arm64`) whose
`codesign -dvvv` shows `flags=0x10000(runtime)`, a timestamp from Apple, the
`apple-events` entitlement and the team's Developer ID authority. `--version` printed the
tag natively and under Rosetta (`arch -x86_64`). `spctl --assess` said
`rejected, source=Unnotarized Developer ID` (a notarized release gets the same answer, see
above). The
designated requirement was byte-for-byte the same as that of a binary installed with
`install-signed` on the same Mac. The build printed a warning that the x86_64
architecture is deprecated for the SDK's default deployment target (macOS 27.0); it still
built, and the binary itself records `minos 15.0` on both slices (it records `sdk 15.0`,
where a `make build` binary records the installed SDK's version; whether that makes any
behavioural difference has not been measured).

The first real submission (v2.7.0, 2026-10-28) was accepted within minutes: notarytool's
log says `Ready for distribution`, no issues, and its ticket lists the arm64 and x86_64
cdhashes of the shipped binary. The ticket cannot be stapled to it (`stapler staple`:
error 73, a plain Mach-O has nowhere to hold one). The build is reproducible: that release
and its rehearsal, built from the same commit, have byte-identical code and the same
cdhashes and differ only in the signature's timestamp. Apple's ticket is keyed by cdhash,
so it covers the rehearsal binary too; the `-DRYRUN` directory and the marker are what
tell the two files apart.

Not measured, so not claimed:

- **How Gatekeeper treats a downloaded release on its first run.** A quarantined copy is
  expected to be checked online (so a first run offline may be refused); not observed.
- **The x86_64 slice on an Intel Mac.** Only `--version` and `--help` under Rosetta.
- **Whether an existing Full Disk Access grant carries over.** The designated requirement
  matches (above), which is what the grant is keyed to, but swapping a release binary in
  and watching the grant keep working has not been done.

Known gaps, tracked: the build runs in the live checkout and does not pin or record the
dependency versions (#309); entitlements are checked for one key rather than for their
content, and the team is not pinned (#310).

## Why a zip is built and then thrown away

`notarytool` takes archives, not bare files. The zip exists only to be submitted and is
not shipped. It is built with `ditto -c -k --norsrc --noextattr`: without `--norsrc` an
AppleDouble `._safari-browser` entry rides along, and Apple's `--keepParent` example (for
`.app` bundles) puts the containing directory, here a random temp name, into the archive
when given a single file. Both were measured on macOS 27.
