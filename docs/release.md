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
| Refuses early: `DEVELOPER_ID` not the 40-hex SHA-1 of a valid *Developer ID Application* certificate in the keychain, tree not clean (untracked files count, and so do untracked files under `Sources/` that git ignores, because SwiftPM compiles them), `HEAD` without exactly one `vX.Y.Z` tag, notary profile not answering | Create or push a tag |
| Builds both architectures from that commit, stamping the tag into the binary | Call `gh`, or publish anything |
| Signs, then verifies: `codesign --verify`, the install-signature guard (`#119`), and that the binary reports the tag | Submit anything for notarization unless `NOTARIZE=1` (signing still asks Apple's *timestamp* server for a timestamp, see below) |
| With `NOTARIZE=1`: submits and waits; only `Accepted` passes, anything else prints the failure (and Apple's log when the answer carried a submission id) and fails | Leave a half-built `dist/` behind: the output name is reserved first and the result is staged and moved in last |
| Writes `dist/<tag>/` and prints the commands for you to run | |

`release.sh` runs from the commit being released, so review what it will run before you
tag: `git diff <previous-tag>..<tag> -- scripts Makefile Package.swift 'Sources/SafariBrowser/*.plist'`.

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
tree with any uncommitted or untracked file. Do not edit, commit or switch branches in
that checkout while it runs (the build takes minutes; #309 tracks making that safe).

```bash
git tag v2.7.0 <commit>          # your decision: the version and the commit. Exactly ONE v* tag on it:
                                 # with several, git would pick one for you, so the script refuses.

DEVELOPER_ID=<sha1> make release-signed                 # rehearsal: nothing is submitted for notarization
DEVELOPER_ID=<sha1> NOTARIZE=1 make release-signed      # the real one: goes to Apple
```

Tags may carry a prerelease part (`v2.7.0-rc.1`); the printed `gh` line then adds
`--prerelease`. A tag ending in `-DRYRUN` is refused (it would collide with the
rehearsal's directory name).

The rehearsal signs for real. Signing with `--timestamp` asks Apple's timestamp server
for a timestamp, which sends it the signature's hash, so a rehearsal is not fully
offline, but nothing is submitted for notarization and the binary never goes to Apple's
notary service. It writes `dist/<tag>-DRYRUN/` with a `DRYRUN-NOT-NOTARIZED` marker file
next to the binary: that marks it for you, but the binary itself is a valid Developer ID
binary that reports the release tag, so do not upload it. For a rehearsal that never
contacts Apple, add `RELEASE_TIMESTAMP=none`; it is refused together with `NOTARIZE=1`.
(A fresh clone still needs the network once for SwiftPM to resolve packages.) The
rehearsal also builds the submission zip, so a `ditto` or `TMPDIR` problem shows up
before the real run.

`dist/<tag>/` holds:

| File | Content |
|---|---|
| `safari-browser` | the signed Universal binary |
| `safari-browser.sha256` | the SHA-256 and nothing else (one line) |
| `NOTARIZATION.json` | notarytool's JSON answer: submission id, message and status (no date) |

On success the script prints three commands. Running them is yours: they are visible to
everyone and cannot be taken back.

```bash
git push origin v2.7.0
git ls-remote origin refs/tags/v2.7.0            # must show the commit the script printed
gh release create v2.7.0 --verify-tag [--prerelease] dist/v2.7.0/safari-browser dist/v2.7.0/safari-browser.sha256 --title v2.7.0
```

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
download, not a swapped one. What ties the file to your Developer ID is the signature
requirement; run the checks before you run the file:

```bash
# in the folder you downloaded to; <TEAM_ID> is the 10-character code in parentheses in
# your certificate's name (security find-identity -v -p codesigning)
test "$(shasum -a 256 < safari-browser | awk '{print $1}')" = "$(cat safari-browser.sha256)" \
  && chmod +x safari-browser \
  && codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>"' safari-browser \
  && spctl --assess --type execute -vv safari-browser \
  && ./safari-browser --version
```

`codesign --verify` on its own accepts any valid signature (an ad-hoc local build
included); the `-R=` requirement is what pins the team. `spctl` should report
`source=Notarized Developer ID` for a notarized release (it reports `Unnotarized
Developer ID` for a rehearsal binary, which is how you tell them apart; the notarized
answer has not been observed yet, see below). Running `safari-browser --version`
without `./` would run whatever is first on your `PATH`, not the download.

## Measured, and not measured

A rehearsal (`NOTARIZE=0`, a real Developer ID, a clean clone on a throwaway tag) on
2026-10-25 gave a 14.9 MB Universal binary (`lipo -archs`: `x86_64 arm64`) whose
`codesign -dvvv` shows `flags=0x10000(runtime)`, a timestamp from Apple, the
`apple-events` entitlement and the team's Developer ID authority. `--version` printed the
tag natively and under Rosetta (`arch -x86_64`). `spctl --assess` said
`rejected, source=Unnotarized Developer ID`, which is the gap notarization closes. The
designated requirement was byte-for-byte the same as that of a binary installed with
`install-signed` on the same Mac. The build printed a warning that the x86_64
architecture is deprecated for the SDK's default deployment target (macOS 27.0); it still
built, and the binary itself records `minos 15.0` on both slices (it records `sdk 15.0`,
where a `make build` binary records the installed SDK's version; whether that makes any
behavioural difference has not been measured).

Not measured, so not claimed:

- **Anything after a real submission.** Whether Apple accepts it, what the notarytool log
  says, and what `spctl` says afterwards. The rehearsal sends nothing to the notary service.
- **Whether the bare binary can be stapled.** `stapler` works on app bundles, disk
  images and installer packages; a plain Mach-O is expected not to take a ticket. If so,
  Gatekeeper checks with Apple online the first time a downloaded (quarantined) copy runs,
  so a first run offline may be refused.
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
