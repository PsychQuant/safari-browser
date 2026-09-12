#!/usr/bin/env python3
"""Measure the dialog contract with at least 15 windows; close only owned fixtures."""
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve()


def applescript(source):
    return subprocess.run(['/usr/bin/osascript', '-e', source], capture_output=True,
                          text=True, timeout=10, check=True).stdout.strip()


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    probe = subprocess.run([str(BINARY), 'dialog', 'list'], capture_output=True, text=True, timeout=3)
    if probe.returncode:
        environmental = ('Accessibility' in probe.stderr or 'GUI session' in probe.stderr
                         or 'native dialog candidates were found' in probe.stderr)
        print(('SKIP' if environmental else 'FAIL') + ': initial dialog inspection failed.')
        return 77 if environmental else 1
    if probe.stdout.startswith('blocking dialog present'):
        print('SKIP: a dialog already exists; fixtures will not be created.')
        return 77
    if probe.stdout.strip() != 'no blocking dialog found':
        print('FAIL: unexpected initial dialog result.')
        return 1
    count = int(applescript('tell application "Safari" to count windows'))
    nonce = uuid.uuid4().hex
    owned = []
    result = 1
    retained = False
    try:
        for index in range(max(1, 15 - count)):
            url = (ROOT / 'Tests/Fixtures/dialog-test.html').as_uri() + f'?windows-{nonce}-{index}'
            window = int(applescript(f'''tell application "Safari"
                make new document with properties {{URL:{quoted(url)}}}
                return id of front window
            end tell'''))
            owned.append((window, url))
        actual = int(applescript('tell application "Safari" to count windows'))
        assert actual >= 15, f'expected at least 15 windows, got {actual}'
        print(f'Windows: {actual}; owned fixtures: {len(owned)}', flush=True)
        for index in range(3):
            start = time.monotonic()
            probe = subprocess.run([str(BINARY), 'dialog', 'list'], capture_output=True, text=True, timeout=2)
            elapsed = time.monotonic() - start
            assert probe.returncode == 0 and probe.stdout.strip() == 'no blocking dialog found', 'scan was not completely clear'
            assert elapsed < 1, f'clear scan took {elapsed:.3f}s'
            print(f'PASS clear scan {index + 1}: {elapsed:.3f}s', flush=True)
        # The existing harness owns a separate nonce tab/dialog and validates
        # ownership before dismissal. Its new checks measure both clear/present.
        env = dict(os.environ, SAFARI_BROWSER_BIN=str(BINARY))
        result = subprocess.run(['bash', str(ROOT / 'Tests/e2e-dialog.sh')], cwd=ROOT, env=env, timeout=360).returncode
    finally:
        for window, url in reversed(owned):
            try:
                outcome = applescript(f'''tell application "Safari"
                    if not (exists window id {window}) then return "gone"
                    set w to window id {window}
                    if (count tabs of w) is not 1 then return "retained"
                    if (URL of current tab of w) is not {quoted(url)} then return "retained"
                    close w
                    return "closed"
                end tell''')
                if outcome not in ('closed', 'gone'):
                    retained = True
                    print(f'Fixture window {window} changed; left untouched.', file=sys.stderr)
            except (subprocess.SubprocessError, OSError):
                retained = True
                print(f'Could not confirm cleanup of owned window {window}.', file=sys.stderr)
        print(f'Owned-window cleanup: {"incomplete" if retained else "complete"}', flush=True)
    return 1 if retained else result


if __name__ == '__main__':
    raise SystemExit(main())
