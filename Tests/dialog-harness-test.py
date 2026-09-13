#!/usr/bin/env python3
"""Safari-free regression checks for the dialog harness failure boundaries."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from dialog_ownership import fixture_is_active, fixture_dialog_expectations, guarded_dismiss

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

class GuardedFixtureTests(unittest.TestCase):
    url = 'file:///tmp/dialog.html?own-nonce'
    message = 'e2e dialog own-nonce'
    warning = '⚠ BLOCKING DIALOG in window id 42: "e2e dialog own-nonce" — buttons: "OK"'

    def listing(self, message):
        import json
        return 'blocking dialog present\n  message: ' + json.dumps(message) + '\n  buttons: "OK"\n'

    def test_measured_prefix_keeps_exact_raw_expectation(self):
        raw = 'JavaScript ' + self.message
        self.assertEqual(fixture_dialog_expectations(self.warning, self.listing(raw), self.url,
                         self.message, lambda _: self.url), (42, raw, 'OK'))
        for raw in ('foreign', self.message + ' extra', 'Other ' + self.message):
            self.assertIsNone(fixture_dialog_expectations(self.warning, self.listing(raw), self.url,
                              self.message, lambda _: self.url))
        self.assertIsNone(fixture_dialog_expectations(self.warning, self.listing(self.message), self.url,
                          self.message, lambda _: 'file:///tmp/dialog.html?foreign'))

    def test_uncertain_dispatch_is_guarded_and_never_repeated(self):
        calls = []
        raw = 'JavaScript ' + self.message
        def run(args, **kwargs):
            calls.append(args)
            if args[0] == 'session-check': return subprocess.CompletedProcess(args, 0, '', '')
            if args[1:3] == ['get', 'title']: return subprocess.CompletedProcess(args, 0, 'fixture', self.warning)
            if args[1:3] == ['dialog', 'list']: return subprocess.CompletedProcess(args, 0, self.listing(raw), '')
            self.assertEqual(args, ['binary', 'dialog', 'dismiss', '--button', 'OK',
                                   '--expect-window-id', '42', '--expect-message', raw])
            return subprocess.CompletedProcess(args, 1, 'unknown outcome', '')
        with tempfile.TemporaryDirectory() as directory:
            args = ('binary', self.url, self.message, 'OK', Path(directory)/'attempt', 'session-check')
            first = guarded_dismiss(*args, run=run, read_current=lambda _: self.url)
            second = guarded_dismiss(*args, run=run, read_current=lambda _: self.url)
        self.assertNotEqual(first.returncode, 0)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(sum(a[1:3] == ['dialog', 'dismiss'] for a in calls), 1)

class CleanupExitTests(unittest.TestCase):
    def run_cleanup(self, failed_operation, original_status=0):
        source = SCRIPT.read_text()
        start = source.index('cleanup() {')
        end = source.index('echo "=== safari-browser blocking-dialog', start)
        with tempfile.TemporaryDirectory(prefix='dialog-cleanup-') as directory:
            root = Path(directory)
            binary = root / 'fake-browser'
            binary.write_text('#!/bin/bash\n'
                              'if [[ "$1" == daemon ]]; then exit 0; fi\n'
                              f'if [[ "$1" == {shlex.quote(failed_operation)} ]]; then exit 1; fi\n'
                              'if [[ "$1" == js ]]; then echo 2; fi\nexit 0\n')
            binary.chmod(0o755)
            work = root / 'fixture'; work.mkdir()
            prelude = f'SB={shlex.quote(str(binary))}\nTMP={shlex.quote(str(work))}\nNAME=fake\nURL=file:///fake?nonce\nFIXTURE_OPENED=1\nowns_fixture_dialog() {{ return 1; }}\n'
            return subprocess.run(['/bin/bash', '-c', prelude + source[start:end] + f'\nexit {original_status}\n'], capture_output=True, text=True, timeout=5)

    def test_failed_recovery_invalidates_success(self):
        result = self.run_cleanup('js')
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_failed_close_invalidates_success(self):
        result = self.run_cleanup('close')
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_cleanup_preserves_original_failure(self):
        self.assertEqual(self.run_cleanup('close', 7).returncode, 7)

    def test_successful_cleanup_preserves_success(self):
        self.assertEqual(self.run_cleanup('nothing').returncode, 0)

    def test_skipped_assertion_does_not_report_accepted(self):
        source = SCRIPT.read_text()
        tail = source[source.index('echo "=== Results:'):]
        result = subprocess.run(['/bin/bash', '-c', 'PASS=1; FAIL=0; SKIP=1\n' + tail],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
