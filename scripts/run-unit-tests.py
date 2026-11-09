#!/usr/bin/env python3
"""Run XCTest with evidence of suite completion, not only process exit (#141)."""
import os
import re
import subprocess
import sys


def main():
    # SwiftPM can propagate an XCTest child's early _exit(0) as success.
    # Require the outer suite summary; a completed individual class is not
    # proof that the remainder of the suite ran. Swift Testing's separate
    # zero-test footer must not mask the XCTest summary.
    child = subprocess.Popen(
        ['swift', 'test', *sys.argv[1:]],
        env=dict(os.environ, SKIP_E2E='1'),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    lines = []
    try:
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
        code = child.wait()
    except KeyboardInterrupt:
        child.terminate()
        child.wait()
        return 130
    if code != 0:
        return code if code > 0 else 1
    # #357: XCTest writes skips between `with` and the failure count
    # ("with 13 tests skipped and 0 failures"). A skip is not a failure, so the
    # clause is optional, and only there; the failure count must still be 0.
    summary = re.search(
        r"^Test Suite '(?:All tests|Selected tests)' passed at [^\n]+\n"
        r"\s*Executed ([1-9][0-9]*) tests?, with (?:([1-9][0-9]*) tests? skipped and )?0 failures \(0 unexpected\)",
        ''.join(lines), re.MULTILINE,
    )
    if summary is None:
        print('FAIL: XCTest completion summary missing or invalid; exit 0 alone is insufficient.', file=sys.stderr)
        return 1
    executed, skipped = summary.group(1), summary.group(2)
    if skipped is None:
        print(f'Verified XCTest completion: {executed} tests.')
    else:
        print(f'Verified XCTest completion: {executed} tests ({skipped} skipped).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
