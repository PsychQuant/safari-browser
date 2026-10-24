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
| Refuses early: no identity, tree not clean, `HEAD` not exactly on a `vX.Y.Z` tag, notary profile not answering | Create or push a tag |
| Builds both architectures from that commit, stamping the tag into the binary | Call `gh`, or publish anything |
| Signs, then verifies: `codesign --verify`, the install-signature guard (`#119`), and that the binary reports the tag | Send anything to Apple unless `NOTARIZE=1` |
| With `NOTARIZE=1`: submits and waits; only `Accepted` passes, anything else prints Apple's log and fails | Leave a half-built `dist/` behind: the result is moved into place last |
| Writes `dist/<tag>/` and prints the commands for you to run | |

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
tree with any uncommitted or untracked file.

```bash
git tag v2.7.0 <commit>                       # your decision: the version and the commit

DEVELOPER_ID=<sha1> make release-signed                 # rehearsal, nothing leaves the Mac
DEVELOPER_ID=<sha1> NOTARIZE=1 make release-signed      # the real one: goes to Apple
```

The rehearsal signs for real (with a real timestamp from Apple's timestamp server, which
receives only the signature's hash) but writes `dist/<tag>-DRYRUN/` with a
`DRYRUN-NOT-NOTARIZED` marker, so it cannot be uploaded by mistake or stop the real run
from using `dist/<tag>/`. For a rehearsal with no network at all, add
`RELEASE_TIMESTAMP=none`; it is refused together with `NOTARIZE=1`.

`dist/<tag>/` holds:

| File | Content |
|---|---|
| `safari-browser` | the signed Universal binary |
| `safari-browser.sha256` | the SHA-256 and nothing else (one line) |
| `NOTARIZATION.json` | Apple's answer, verbatim: submission id and status |

On success the script prints the two commands that publish it (`git push origin <tag>`,
`gh release create <tag> …`). Running them is yours: they are visible to everyone and
cannot be taken back.

## When Apple says no

The script prints the status, then the output of `xcrun notarytool log <id>`, and exits
non-zero with nothing left in `dist/`. Typical causes: a signature without a secure
timestamp, no hardened runtime, or a certificate that is not a Developer ID one. The
first two are what distinguishes this target from `install-signed`.

## Checking a downloaded copy

```bash
test "$(shasum -a 256 < safari-browser | awk '{print $1}')" = "$(cat safari-browser.sha256)" && echo ok
codesign --verify --strict --verbose=2 safari-browser
safari-browser --version          # the tag
```

## Measured, and not measured

A rehearsal (`NOTARIZE=0`, a real Developer ID, a clean clone on a throwaway tag) on
2026-10-25 gave a 14.9 MB Universal binary (`lipo -archs`: `x86_64 arm64`) whose
`codesign -dvvv` shows `flags=0x10000(runtime)`, a timestamp from Apple, the
`apple-events` entitlement and the team's Developer ID authority. `--version` printed the
tag natively and under Rosetta (`arch -x86_64`). `spctl --assess` said
`rejected, source=Unnotarized Developer ID`, which is the gap notarization closes. The
designated requirement was byte-for-byte the same as that of a binary installed with
`install-signed` on the same Mac. The build printed a warning that the x86_64
architecture is deprecated for a macOS 27.0 deployment target; it still built.

Not measured, so not claimed:

- **Anything after a real submission.** Whether Apple accepts it, what the notarytool log
  says, and what `spctl` says afterwards. The rehearsal sends nothing to Apple.
- **Whether the bare binary can be stapled.** `stapler` works on app bundles, disk
  images and installer packages; a plain Mach-O is expected not to take a ticket. If so,
  Gatekeeper checks with Apple online the first time a downloaded (quarantined) copy runs,
  so a first run offline may be refused.
- **The x86_64 slice on an Intel Mac.** Only `--version` and `--help` under Rosetta.
- **Whether an existing Full Disk Access grant carries over.** The designated requirement
  matches (above), which is what the grant is keyed to, but swapping a release binary in
  and watching the grant keep working has not been done.

## Why a zip is built and then thrown away

`notarytool` takes archives, not bare files. The zip exists only to be submitted and is
not shipped. It is built with `ditto -c -k --norsrc --noextattr`: without `--norsrc` an
AppleDouble `._safari-browser` entry rides along, and Apple's `--keepParent` example (for
`.app` bundles) puts the containing directory, here a random temp name, into the archive
when given a single file. Both were measured on macOS 27.
