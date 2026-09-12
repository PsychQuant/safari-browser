#!/usr/bin/env python3
"""Safari-free checks for #131's GUI harness and destructive boundaries."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    'background_dialog', Path(__file__).with_name('e2e-background-dialog.py'))
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


def result(stdout='', stderr='', code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class BackgroundHarnessTests(unittest.TestCase):
    image_id = '12345678123412341234123456789abc'

    def test_uuid_parser_selects_exact_host_arch_and_normalizes(self):
        output = ('UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /tmp/browser\n'
                  'UUID: FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF (x86_64) /tmp/browser\n')
        self.assertEqual(harness.parse_image_identifier(output, 'arm64'), self.image_id)
        self.assertEqual(harness.parse_image_identifier(output, 'x86_64'), 'f' * 32)

    def test_uuid_parser_refuses_unknown_malformed_or_ambiguous_output(self):
        row = 'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /tmp/browser\n'
        for output, arch in [('', 'arm64'), (row, 'riscv64'), (row, 'x86_64'),
                             (row + row, 'arm64'), ('warning: unreadable\n' + row, 'arm64'),
                             (row.replace('123456789ABC', 'unknown'), 'arm64')]:
            with self.subTest(output=output, arch=arch):
                with self.assertRaises(harness.VerificationError):
                    harness.parse_image_identifier(output, arch)

    def test_unknown_build_preflight_stops_before_gui_construction(self):
        with patch.object(harness, 'session_preflight', return_value=0), \
                patch.object(harness, 'image_identifier', side_effect=harness.VerificationError('unknown UUID')), \
                patch.object(harness, 'Harness') as gui:
            self.assertEqual(harness.main([]), 1)
        gui.assert_not_called()

    def test_dwarfdump_failure_is_rejected_without_running_selected_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'browser'
            binary.touch(mode=0o755)
            with patch.object(harness, 'run', return_value=result(stderr='bad image', code=1)) as run:
                with self.assertRaises(harness.VerificationError):
                    harness.image_identifier(binary)
        self.assertEqual(run.call_args.args[0], ['/usr/bin/dwarfdump', '--uuid', str(binary)])

    def test_cli_enables_identified_worker_and_preserves_other_environment(self):
        with patch.dict(os.environ, {'SAFARI_BROWSER_MCP_DIRECT': 'old',
                                     'SAFARI_BROWSER_MCP_IMAGE_ID': 'old-build',
                                     'HARNESS_KEEP_ENV': 'preserved'}):
            gui = self.make_harness()
        with patch.object(harness, 'run', return_value=result()) as run:
            gui.cli('js', '1+1', timeout=45)
        self.assertEqual(run.call_args.args[0], ['/unused/browser', '__mcp-exec', 'js', '1+1'])
        env = run.call_args.kwargs['env']
        self.assertEqual(env['SAFARI_BROWSER_MCP_DIRECT'], '1')
        self.assertEqual(env['SAFARI_BROWSER_MCP_IMAGE_ID'], self.image_id)
        self.assertEqual(env['HARNESS_KEEP_ENV'], 'preserved')
        self.assertNotIn('SAFARI_BROWSER_DAEMON', env)

    def test_timeout_kills_owned_fake_descendant_before_it_can_write(self):
        with tempfile.TemporaryDirectory() as directory:
            ready, late = Path(directory) / 'ready', Path(directory) / 'late'
            child = (f'from pathlib import Path; import time; Path({str(ready)!r}).touch(); '
                     f'time.sleep(1.5); Path({str(late)!r}).touch()')
            parent = (f'import subprocess,sys; subprocess.Popen([sys.executable,"-c",{child!r}]).wait()')
            with self.assertRaises(subprocess.TimeoutExpired):
                harness.run([sys.executable, '-c', parent], timeout=0.5)
            self.assertTrue(ready.exists(), 'fake descendant never started')
            time.sleep(1.2)
            self.assertFalse(late.exists(), 'owned descendant escaped timeout cleanup')

    def test_group_preflight_accepts_inheritance_and_refuses_escape_or_no_child(self):
        for mode in ('inherit', 'escape', 'absent'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                binary = Path(directory) / 'fake-browser'
                binary.write_text(
                    f'#!{sys.executable}\n'
                    'import json,subprocess,sys\n'
                    'assert sys.argv[1:]==["__mcp-exec","exec"]\n'
                    'assert json.load(sys.stdin)==[{"cmd":"wait","args":["2000"]}]\n'
                    + ('' if mode == 'absent' else
                       'subprocess.Popen([sys.executable,"-c","import time; time.sleep(0.4)"],'
                       f'start_new_session={mode == "escape"!r}).wait()\n'))
                binary.chmod(0o755)
                gui = self.make_harness()
                gui.binary = binary
                with patch.object(harness.os, 'killpg', wraps=os.killpg) as kill:
                    if mode == 'inherit':
                        gui.verify_process_group()
                        self.assertEqual(kill.call_count, 1)
                    else:
                        with self.assertRaises(harness.VerificationError):
                            gui.verify_process_group()
                        kill.assert_not_called()

    def test_group_preflight_failure_prevents_gui_exercise(self):
        with patch.object(harness, 'session_preflight', return_value=0), \
                patch.object(harness, 'image_identifier', return_value=self.image_id), \
                patch.object(harness, 'Harness') as gui:
            gui.return_value.verify_process_group.side_effect = harness.VerificationError('escaped group')
            gui.return_value.cleanup.return_value = True
            self.assertEqual(harness.main([]), 1)
        gui.return_value.exercise.assert_not_called()
    def test_locked_preflight_never_calls_safari_or_reports_pass(self):
        with patch.object(harness, 'session_preflight', return_value=77), \
                patch.object(harness, 'Harness') as gui, \
                patch('builtins.print') as output:
            self.assertEqual(harness.main([]), 77)
        gui.assert_not_called()
        self.assertNotIn('PASS', str(output.call_args_list))

    def test_preflight_only_never_constructs_gui_harness(self):
        with patch.object(harness, 'session_preflight', return_value=0), \
                patch.object(harness, 'Harness') as gui:
            self.assertEqual(harness.main(['--preflight-only']), 0)
        gui.assert_not_called()

    def test_real_entrypoint_locked_check_returns_77_before_binary_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checker = root / 'locked'
            checker.write_text('#!/bin/sh\nexit 77\n')
            checker.chmod(0o755)
            # The browser must never execute, even when not using --preflight-only.
            binary = root / 'browser'
            binary.write_text('#!/bin/sh\necho BROWSER_CALLED >&2\nexit 1\n')
            binary.chmod(0o755)
            env = dict(os.environ, DIALOG_TEST_SESSION_CHECK=str(checker),
                       SAFARI_BROWSER_BIN=str(binary))
            actual = subprocess.run([sys.executable, str(Path(harness.__file__))],
                                    env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(actual.returncode, 77, actual)
        self.assertNotIn('BROWSER_CALLED', actual.stderr)
        self.assertNotIn('PASS', actual.stdout + actual.stderr)

    def test_original_timeout_and_recovery_hints_are_required(self):
        good = result(stderr='Process timed out after 30 seconds: /usr/bin/osascript\n'
                             'Target is background; tab focus then dialog list', code=1)
        harness.verify_timeout(good, 30.1)
        for bad, elapsed in [(good, 0.1), (result(stderr=good.stderr), 30.1),
                             (result(stderr='background tab focus dialog list', code=1), 30.1),
                             (result(stderr='Process timed out after 30 seconds', code=1), 30.1)]:
            with self.subTest(bad=bad, elapsed=elapsed):
                with self.assertRaises(harness.VerificationError):
                    harness.verify_timeout(bad, elapsed)

    def make_harness(self):
        gui = harness.Harness(Path('/unused/browser'), Path('/unused/session-check'), self.image_id)
        gui.window_id = 42
        gui.armed = True
        gui.check_session = Mock(return_value=True)
        gui.native = Mock(return_value='owned')
        gui.current_url = Mock(return_value=gui.url)
        return gui

    def evidence(self, gui):
        listing = result('blocking dialog present\n'
                         f'  message: "{gui.dialog_text}"\n  buttons: "OK"\n')
        title = result('Dialog Test Page\n',
                       f'⚠ BLOCKING DIALOG in window id 42: "{gui.dialog_text}" — buttons: "OK"')
        return title, listing

    def test_owned_dialog_requires_window_url_nonce_and_readable_button(self):
        gui = self.make_harness()
        title, listing = self.evidence(gui)
        self.assertEqual(gui.owned_button(title, listing), 'OK')
        for bad_title, bad_listing in [
            (result(title.stdout, title.stderr.replace('id 42:', 'id 43:')), listing),
            (result(title.stdout, title.stderr + '\n' + title.stderr), listing),
            (title, result(listing.stdout.replace(gui.dialog_text, 'other dialog'))),
            (title, result(listing.stdout.replace('"OK"', '"OK", "Cancel"'))),
            (result(title.stdout, title.stderr, 1), listing),
            (title, result(listing.stdout, code=1)),
        ]:
            self.assertIsNone(gui.owned_button(bad_title, bad_listing))
        gui.current_url.return_value = gui.cover_url
        self.assertIsNone(gui.owned_button(title, listing))

    def test_replacement_after_observation_cannot_receive_a_press(self):
        gui = self.make_harness()
        title, listing = self.evidence(gui)
        gui.target = Mock(return_value=title)
        foreign_presses = []

        def command(*args, **kwargs):
            if args[:2] == ('dialog', 'list'):
                return listing
            self.assertEqual(args[:2], ('dialog', 'dismiss'))
            # A different window/message appears after the last ownership read.
            # Model the command boundary: supplied expectations reject it;
            # an unguarded command instead adopts the new dialog.
            expected = ('--expect-window-id' in args and '--expect-message' in args
                        and args[args.index('--expect-window-id') + 1] == str(gui.window_id)
                        and args[args.index('--expect-message') + 1] == gui.dialog_text)
            if expected:
                return result(stderr='expectation mismatch; no button pressed', code=64)
            foreign_presses.append('user dialog')
            return result(stdout='dismissing dialog: user dialog; pressed')

        gui.cli = command
        with self.assertRaises(harness.VerificationError):
            gui.dismiss_owned()
        self.assertEqual(foreign_presses, [])
        self.assertTrue(gui.armed)

    def test_unknown_dialog_cleanup_never_dismisses_or_closes(self):
        gui = self.make_harness()
        gui.cli = Mock(return_value=result('no blocking dialog found'))
        self.assertFalse(gui.cleanup())
        calls = [call.args for call in gui.cli.call_args_list]
        self.assertFalse(any('dismiss' in call or 'close' in call for call in calls))
        self.assertFalse(any('close w' in call.args[0] for call in gui.native.call_args_list))

    def test_changed_fixture_cleanup_never_touches_dialog(self):
        gui = self.make_harness()
        gui.native.return_value = 'retained'
        gui.cli = Mock()
        self.assertFalse(gui.cleanup())
        gui.cli.assert_not_called()

    def test_locked_cleanup_never_interacts_with_safari(self):
        gui = self.make_harness()
        gui.check_session.return_value = False
        gui.cli = Mock()
        self.assertFalse(gui.cleanup())
        gui.cli.assert_not_called()
        gui.native.assert_not_called()

    def test_cleanup_closes_only_after_rechecking_exact_owned_tabs(self):
        gui = self.make_harness()
        gui.armed = False
        gui.cli = Mock(return_value=result('no blocking dialog found'))
        gui.native.side_effect = lambda source: 'closed' if 'close w' in source else 'owned'
        self.assertTrue(gui.cleanup())
        close_script = gui.native.call_args.args[0]
        self.assertIn('window id 42', close_script)
        self.assertIn('if (count tabs of w) is not 2 then return "retained"', close_script)
        self.assertIn(harness.quoted(gui.url), close_script)
        self.assertIn(harness.quoted(gui.cover_url), close_script)

    def test_cleanup_recovery_uses_native_title_and_named_verified_button(self):
        gui = self.make_harness()
        title, listing = self.evidence(gui)
        gui.cli = Mock(side_effect=[title, listing, result(gui.dialog_text),
                                   result('no blocking dialog found')])
        gui.native.side_effect = lambda source: 'closed' if 'close w' in source else 'owned'
        self.assertTrue(gui.cleanup())
        self.assertFalse(gui.armed)
        self.assertEqual(gui.cli.call_args_list[0].args,
                         ('get', 'title', '--url-exact', gui.url))
        self.assertEqual(gui.cli.call_args_list[2].args, ('dialog', 'dismiss', '--button', 'OK',
                                                                  '--expect-window-id', str(gui.window_id),
                                                                  '--expect-message', gui.dialog_text))

    def test_incomplete_cleanup_prevents_acceptance_pass(self):
        with patch.object(harness, 'session_preflight', return_value=0), \
                patch.object(harness, 'image_identifier', return_value=self.image_id), \
                patch.object(harness, 'Harness') as gui, \
                patch('builtins.print') as output:
            gui.return_value.exercise.return_value = 0
            gui.return_value.cleanup.return_value = False
            self.assertEqual(harness.main([]), 1)
        self.assertFalse(any(str(call.args[0]).startswith('PASS:')
                             for call in output.call_args_list))


if __name__ == '__main__':
    unittest.main()
