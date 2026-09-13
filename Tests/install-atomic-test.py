#!/usr/bin/env python3
"""Exercise actual install recipes against private Mach-O fixtures, never ~/bin.

A Developer ID identity is required for complete coverage. Missing identity exits
77 (incomplete), never PASS. --mutation-check also proves that replacing rename
with an in-place copy is detected for both install modes.
"""
import argparse
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def invoke(argv, **kwargs):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=60, **kwargs)


def identity():
    supplied = os.environ.get("DEVELOPER_ID")
    if supplied:
        return supplied
    found = invoke(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    for line in found.stdout.splitlines():
        if "Developer ID Application" in line:
            match = re.search(r"\b[0-9A-F]{40}\b", line)
            if match:
                return match.group()
    return None


class Harness:
    def __init__(self, temporary, guard, certificate):
        self.tmp = temporary
        self.guard = guard
        self.certificate = certificate
        self.name = "atomic-install-fixture-" + uuid.uuid4().hex
        self.release = ROOT / ".build/release"
        self.created_release = not self.release.exists()
        self.release.mkdir(parents=True, exist_ok=True)
        self.source_binary = self.release / self.name
        self.c_source = self.tmp / "fixture.c"
        self.c_source.write_text('''#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  puts(VERSION); fflush(stdout);
  if (argc > 1 && strcmp(argv[1], "--hold") == 0) { for (;;) pause(); }
  return 0;
}
''')
        self.wrappers = self.tmp / "wrappers"
        self.wrappers.mkdir()
        self.write_wrapper("codesign", '''
for last do :; done
[ "$last" != "$ATOMIC_DEST" ] || exit 91
printf 'sign:%s\\n' "$last" >> "$ATOMIC_TRACE"
[ "$ATOMIC_FAIL_SIGN" != 1 ] || exit 92
exec /usr/bin/codesign "$@"
''')
        self.verify = self.write_wrapper("verify", '''
for last do :; done
printf 'verify:%s\\n' "$last" >> "$ATOMIC_TRACE"
if [ "$ATOMIC_FAIL_VERIFY" = 1 ] && [ "$last" != "$ATOMIC_DEST" ]; then exit 93; fi
exec ''' + shlex.quote(str(guard)) + ''' "$@"
''')
        self.checks = 0

    def write_wrapper(self, name, body):
        path = self.wrappers / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def compile(self, version):
        result = invoke(["/usr/bin/clang", '-DVERSION="' + version + '"',
                         str(self.c_source), "-Wl,-sectcreate,__TEXT,__info_plist," +
                         str(ROOT / "Sources/SafariBrowser/Info.plist"),
                         "-o", str(self.source_binary)])
        require(result.returncode == 0, "fixture compilation failed")

    def execute(self, target, directory, makefile, failure=None):
        destination = directory / self.name
        trace = directory / "trace"
        trace.write_text("")
        env = os.environ.copy()
        env.update(PATH=str(self.wrappers) + os.pathsep + env.get("PATH", ""),
                   DEVELOPER_ID=self.certificate,
                   ATOMIC_DEST=str(destination), ATOMIC_TRACE=str(trace),
                   ATOMIC_FAIL_SIGN="1" if failure == "sign" else "0",
                   ATOMIC_FAIL_VERIFY="1" if failure == "verify" else "0")
        # Ignore caller make flags so this harness cannot accidentally request a
        # build or parallelize prerequisites. -o build preserves the real recipe.
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKEFILES"):
            env.pop(key, None)
        result = invoke(["/usr/bin/make", "--no-print-directory", "-f", str(makefile),
                         "-o", "build", "-o", str(self.guard), target,
                         "BINARY_NAME=" + self.name, "INSTALL_DIR=" + str(directory),
                         "VERIFY_BIN=" + str(self.guard), "VERIFY_SIG=" + str(self.verify)],
                        cwd=ROOT, env=env)
        # Do not publish codesign output: it can contain local identity names.
        return result.returncode, trace.read_text().splitlines()

    def no_stages(self, directory):
        require(not list(directory.glob(self.name + ".*")), "staging file leaked")

    def stage_paths(self, trace, operation, destination):
        paths = [Path(line.split(":", 1)[1]) for line in trace
                 if line.startswith(operation + ":")]
        require(paths, operation + " was not exercised")
        require(all(path.parent == destination.parent and path != destination
                    and path.name.startswith(self.name + ".") for path in paths),
                operation + " did not use a private sibling stage")

    def check(self, target, makefile, mutate=False):
        directory = self.tmp / (target + ("-mutant" if mutate else ""))
        directory.mkdir()
        destination = directory / self.name
        self.compile("old")
        code, trace = self.execute(target, directory, makefile)
        require(code == 0, target + ": initial install failed")
        self.stage_paths(trace, "sign", destination)
        self.no_stages(directory)
        old_fd = destination.open("rb")
        old_bytes = old_fd.read()
        old_inode = destination.stat().st_ino
        holder = subprocess.Popen([str(destination), "--hold"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(holder.stdout, selectors.EVENT_READ)
                require(ready.select(timeout=5), target + ": old process failed to start")
            require(holder.stdout.readline().strip() == "old", "old process wrong version")
            self.compile("new")
            code, trace = self.execute(target, directory, makefile)
            if mutate:
                # Check the same invariant before launching a potentially invalid
                # inode. No known-bad fixture is ever installed outside this TMP.
                require(destination.stat().st_ino != old_inode, "fresh inode required")
                raise AssertionError("copy mutation escaped fresh-inode assertion")
            require(code == 0, target + ": replacement install failed")
            require(destination.stat().st_ino != old_inode, "fresh inode required")
            require(os.fstat(old_fd.fileno()).st_ino == old_inode, "old FD identity changed")
            old_fd.seek(0)
            require(old_fd.read() == old_bytes, "old FD bytes overwritten")
            require(holder.poll() is None, "old running process was killed")
            new = invoke([str(destination)])
            require(new.returncode == 0 and new.stdout.strip() == "new", "new binary cannot launch")
            self.stage_paths(trace, "sign", destination)
            if target == "install-signed":
                verifies = [line for line in trace if line.startswith("verify:")]
                require(len(verifies) == 2, "signed install must verify stage and destination")
                self.stage_paths(verifies[:1], "verify", destination)
                require(verifies[1] == "verify:" + str(destination), "landed binary not verified")
            self.no_stages(directory)
            self.checks += 1
            print("PASS", target, "stages, replaces inode, preserves running old binary, launches new binary")
            self.compile("rejected")
            for failure in (["sign", "verify"] if target == "install-signed" else ["sign"]):
                before = destination.read_bytes()
                before_inode = destination.stat().st_ino
                code, trace = self.execute(target, directory, makefile, failure)
                require(code != 0, failure + " injection incorrectly succeeded")
                require(destination.stat().st_ino == before_inode and destination.read_bytes() == before,
                        failure + " failure replaced the working binary")
                self.stage_paths(trace, failure, destination)
                self.no_stages(directory)
                require(holder.poll() is None, failure + " failure killed old process")
                launched = invoke([str(destination)])
                require(launched.returncode == 0 and launched.stdout.strip() == "new",
                        failure + " failure left an unlaunchable binary")
                self.checks += 1
                print("PASS", target, failure, "failure preserves destination and removes staging")
        finally:
            if holder.poll() is None:
                holder.terminate()
            holder.communicate(timeout=5)
            old_fd.close()

    def cleanup(self):
        self.source_binary.unlink(missing_ok=True)
        if self.created_release:
            try:
                self.release.rmdir()
            except OSError:
                pass  # Another build may now own entries; never remove them.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guard", type=Path, default=ROOT / ".build/verify-install-signature")
    parser.add_argument("--mutation-check", action="store_true")
    args = parser.parse_args()
    certificate = identity()
    if certificate is None:
        print("INCOMPLETE: Developer ID signing identity unavailable; atomic signed coverage did not run.")
        return 77
    guard = args.guard.resolve()
    if not guard.is_file() or not os.access(guard, os.X_OK):
        print("FAIL: compiled signature guard unavailable; build it before running this suite.")
        return 1
    with tempfile.TemporaryDirectory(prefix="safari-install-atomic-") as temporary:
        harness = Harness(Path(temporary), guard, certificate)
        try:
            makefile = ROOT / "Makefile"
            for target in ("install", "install-signed"):
                harness.check(target, makefile)
            if args.mutation_check:
                source = makefile.read_text()
                needle = 'mv -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"'
                require(source.count(needle) == 2, "mutation target drift: expected two rename recipes")
                mutant = Path(temporary) / "Makefile.copy-mutant"
                mutant.write_text(source.replace(needle, 'cp -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"'))
                for target in ("install", "install-signed"):
                    try:
                        harness.check(target, mutant, mutate=True)
                    except AssertionError as error:
                        require(str(error) == "fresh inode required", "mutant failed outside expected assertion")
                        print("KILLED", target, "in-place-copy mutation: fresh inode required")
                        harness.checks += 1
                    else:
                        raise AssertionError("copy mutation unexpectedly survived")
            print("Results:", harness.checks, "passed, 0 failed, 0 skipped")
            return 0
        except (AssertionError, subprocess.TimeoutExpired, OSError) as error:
            print("FAIL:", error)
            return 1
        finally:
            harness.cleanup()


if __name__ == "__main__":
    sys.exit(main())
