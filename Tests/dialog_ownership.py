"""Conservative ownership check for a test-created native dialog."""
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def fixture_is_active(warning, expected_url, read_current_url):
    matches = re.findall(r'^⚠ BLOCKING DIALOG in window id ([1-9][0-9]*):', warning, re.MULTILINE)
    if len(matches) != 1:
        return False
    try:
        current = urlsplit(read_current_url(int(matches[0])).strip())
        expected = urlsplit(expected_url)
        return (current.scheme == expected.scheme == 'file'
                and current.netloc in ('', 'localhost')
                and expected.netloc in ('', 'localhost')
                and posixpath.normpath(unquote(current.path)) == posixpath.normpath(unquote(expected.path))
                and current.query == expected.query)
    except (ValueError, OSError, subprocess.SubprocessError):
        return False


def read_current_url(window_id):
    result = subprocess.run(
        ['/usr/bin/osascript', '-e', f'tell application "Safari" to get URL of current tab of window id {window_id}'],
        capture_output=True, text=True, timeout=3, check=True)
    return result.stdout


def fixture_dialog_expectations(warning, listing, expected_url, expected_message, read_current):
    """Return exact press expectations only for this visible nonce fixture.

    Safari 27 prepends its native 'JavaScript' heading to the message. Accept
    only the two measured shapes; pass the observed raw text without stripping
    that heading into the production command's exact-message guard.
    """
    if not fixture_is_active(warning, expected_url, read_current):
        return None
    if expected_message not in warning:
        return None
    lines = listing.splitlines()
    if not lines or lines[0] != 'blocking dialog present':
        return None
    messages = [line[11:] for line in lines if line.startswith('  message: ')]
    buttons = [line[11:] for line in lines if line.startswith('  buttons: ')]
    if len(messages) != 1 or len(buttons) != 1:
        return None
    try:
        message, button = json.loads(messages[0]), json.loads(buttons[0])
    except (ValueError, TypeError):
        return None
    if message not in (expected_message, 'JavaScript ' + expected_message):
        return None
    if not isinstance(button, str) or not button or any(ord(c) < 32 for c in button):
        return None
    window_id = int(re.search(r'^⚠ BLOCKING DIALOG in window id ([1-9][0-9]*):', warning, re.MULTILINE)[1])
    return window_id, message, button


def guarded_dismiss(binary, expected_url, expected_message, button, attempt_file, session_check,
                    *, run=subprocess.run, read_current=read_current_url):
    def refuse(message):
        return subprocess.CompletedProcess([], 1, '', message + '\n')
    attempt_file = Path(attempt_file)
    if attempt_file.exists():
        return refuse('A dismissal was already attempted; no press retry.')
    try:
        if run([str(session_check)], capture_output=True, text=True, timeout=3).returncode:
            return refuse('GUI session is unavailable; fixture retained.')
        title = run([str(binary), 'get', 'title', '--url-exact', expected_url],
                    capture_output=True, text=True, timeout=10)
        listing = run([str(binary), 'dialog', 'list'], capture_output=True, text=True, timeout=3)
        if title.returncode or listing.returncode:
            return refuse('Dialog ownership could not be read; no button pressed.')
        expected = fixture_dialog_expectations(title.stderr, listing.stdout, expected_url,
                                               expected_message, read_current)
        if expected is None or expected[2] != button:
            return refuse('Dialog ownership or button changed; no button pressed.')
        # Persistent across shell functions/subprocesses and cleanup. Atomic
        # create prevents concurrent helpers from both dispatching a press.
        fd = os.open(attempt_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        window_id, raw_message, _ = expected
        return run([str(binary), 'dialog', 'dismiss', '--button', button,
                    '--expect-window-id', str(window_id), '--expect-message', raw_message],
                   capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError, ValueError):
        return refuse('Fixture dismissal could not be confirmed; do not retry the press.')


if __name__ == '__main__':
    if len(sys.argv) == 2:
        raise SystemExit(0 if fixture_is_active(sys.stdin.read(), sys.argv[1], read_current_url) else 1)
    if len(sys.argv) == 8 and sys.argv[1] == 'dismiss':
        result = guarded_dismiss(*sys.argv[2:])
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    raise SystemExit(1)
