#!/usr/bin/env python3
"""Safari-free regression checks for the dialog harness failure boundaries."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from dialog_ownership import fixture_is_active

SCRIPT = Path(__file__).with_name('e2e-dialog.sh')

class HarnessBoundaryTests(unittest.TestCase):
    def run_harness(self, *, missing_clock=False, invalid_clock=False, broken_temp=False, known_dialog=False, locked=False):
        with tempfile.TemporaryDirectory(prefix='dialog-harness-') as directory:
            root = Path(directory)
            log = root / 'calls'
            def executable(name, body):
                file = root / name
                file.write_text('#!/bin/bash\n' + body)
                file.chmod(0o755)
                return file
            executable('pgrep', 'exit 0\n')
            executable('sleep', 'exit 0\n')
            if missing_clock:
                executable('python3', 'exit 127\n')
            if invalid_clock:
                executable('python3', 'echo not-an-integer; exit 0\n')
            if broken_temp:
                executable('mktemp', 'exit 1\n')
            response = 'blocking dialog present' if known_dialog else 'unexpected daemon failure'
            code = 0 if known_dialog else 2
            binary = executable('fake-browser',
                f'echo "$*" >> {shlex.quote(str(log))}\n'
                f'if [[ "$1" == dialog ]]; then echo {shlex.quote(response)}; exit {code}; fi\nexit 1\n')
            session_check = executable('session-check', 'exit 77\n' if locked else 'exit 0\n')
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       SAFARI_BROWSER_BIN=str(binary), DIALOG_TEST_SESSION_CHECK=str(session_check))
            result = subprocess.run(['/bin/bash', str(SCRIPT)], capture_output=True, text=True, env=env, timeout=10)
            return result, log.read_text() if log.exists() else ''

    def test_cli_failure_is_failure_not_environment_skip(self):
        result, _ = self.run_harness()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_clock_failure_stops_before_browser_calls(self):
        result, calls = self.run_harness(missing_clock=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(calls, '')

    def test_non_integer_clock_stops_before_browser_calls(self):
        result, calls = self.run_harness(invalid_clock=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(calls, '')

    def test_temp_failure_stops_before_browser_calls(self):
        result, calls = self.run_harness(broken_temp=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(calls, '')

    def test_locked_session_skips_before_browser_calls(self):
        result, calls = self.run_harness(locked=True)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertEqual(calls, '')

    def test_known_existing_dialog_remains_environment_skip(self):
        result, _ = self.run_harness(known_dialog=True)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)

class DialogOwnershipTests(unittest.TestCase):
    warning = '⚠ BLOCKING DIALOG in window id 42: "test" — buttons: "OK"'
    url = 'file:///tmp/test%20folder/dialog-test.html?unique-marker'

    def test_requires_current_fixture_in_the_warned_window(self):
        ids = []
        def read(window_id):
            ids.append(window_id)
            return 'file:///tmp/test%20folder/dialog-test.html?unique-marker'
        self.assertTrue(fixture_is_active(self.warning, self.url, read))
        self.assertEqual(ids, [42])
        self.assertFalse(fixture_is_active(self.warning, self.url, lambda _: 'https://example.com/?unique-marker'))
        self.assertFalse(fixture_is_active(self.warning, self.url, lambda _: 'file:///tmp/test%20folder/dialog-test.html?other-run'))

    def test_unknown_warning_cannot_authorize_dismissal(self):
        def unexpected_read(_):
            self.fail('unknown or ambiguous evidence must not trigger an AppleScript read')
        self.assertFalse(fixture_is_active('could not inspect window', self.url, unexpected_read))
        self.assertFalse(fixture_is_active(self.warning + '\n' + self.warning, self.url, unexpected_read))

    def test_current_tab_read_failure_is_not_permission(self):
        def read(_):
            raise subprocess.TimeoutExpired('osascript', 3)
        self.assertFalse(fixture_is_active(self.warning, self.url, read))

if __name__ == '__main__':
    unittest.main()
