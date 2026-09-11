"""Conservative ownership check for a test-created native dialog."""
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


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(1)
    raise SystemExit(0 if fixture_is_active(sys.stdin.read(), sys.argv[1], read_current_url) else 1)
