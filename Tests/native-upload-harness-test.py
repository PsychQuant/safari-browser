#!/usr/bin/env python3
"""Non-GUI tests for native-upload-live.py; no Safari or pasteboard access."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import argparse

spec = importlib.util.spec_from_file_location('native_upload_live', Path(__file__).with_name('native-upload-live.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class AcceptanceTests(unittest.TestCase):
    expected = {'name': '.隱藏 空白\'檔案.txt', 'size': 12, 'sha256': 'a' * 64}
    def result(self, case='success', **changes):
        values = dict(command={'status': 'ok', 'exitCode': 0, 'confirmationCount': 1, 'timeoutObserved': False, 'diagnosticsComplete': True},
                      page={'count': 1, 'name': self.expected['name'], 'size': 12, 'hash': 'a' * 64, 'trusted': True},
                      expected=self.expected, observed_panel=True, observer='observed', clipboard_equal=True, cleanup='closed')
        values.update(changes)
        return fixture.acceptance(case, **values)
    def testPositiveRequiresReceiptBytesAndCleanup(self):
        self.assertEqual(self.result()['status'], 'pass')
        for changes in ({'cleanup': 'retained'}, {'clipboard_equal': False}, {'page': {'count': 0}},
                        {'command': {'status': 'timeout', 'exitCode': -9}},
                        {'command': {'status': 'error', 'exitCode': 1, 'cleanupFailed': True}},
                        {'page': {'count': 1, 'name': self.expected['name'], 'size': 12, 'hash': 'b' * 64, 'trusted': True}}):
            self.assertEqual(self.result(**changes)['status'], 'fail')
    def testNegativeCannotCountSuccessfulCommandOrReceipt(self):
        self.assertEqual(self.result('cancel', observer='cancelled')['status'], 'fail')
        command = {'status': 'error', 'exitCode': 1, 'confirmationCount': 0, 'timeoutObserved': True, 'diagnosticsComplete': True}
        self.assertEqual(self.result('timeout', command=command)['status'], 'fail')
    def testNegativeMustObservePanelAndNeverAcceptOuterKill(self):
        command = {'status': 'error', 'exitCode': 1, 'confirmationCount': 0, 'timeoutObserved': True, 'diagnosticsComplete': True}
        page = {'count': 0, 'trusted': False, 'hash': None}
        self.assertEqual(self.result('timeout', command=command, page=page, observed_panel=False, observer='not-observed')['status'], 'skip')
        self.assertEqual(self.result('timeout', command={**command, 'status': 'timeout'}, page=page)['status'], 'fail')
        self.assertEqual(self.result('timeout', command=command, page=page)['status'], 'pass')
        self.assertEqual(self.result('cancel', command=command, page=page, observer='cancelled')['status'], 'pass')
        self.assertEqual(self.result('cancel', command=command, page=page, observer='unknown')['status'], 'fail')
    def testNegativeConfirmationCannotPass(self):
        command = {'status': 'error', 'exitCode': 1, 'confirmationCount': 1, 'timeoutObserved': True, 'diagnosticsComplete': True}
        self.assertEqual(self.result('timeout', command=command, page={'count': 0})['status'], 'fail')

class OwnershipTests(unittest.TestCase):
    marker = 'sb-upload-' + 'a' * 32
    url = 'http://127.0.0.1:43123/' + marker
    def testNoOptInNeverConstructsRunner(self):
        with patch.object(fixture, 'Runner') as runner, patch('builtins.print'):
            self.assertEqual(fixture.main([]), 77)
            runner.assert_not_called()
    def testIdentityRejectsInjectionAndNonexactTarget(self):
        for window, url, marker in [(True, self.url, self.marker), (0, self.url, self.marker),
                                    (42, self.url + '/other', self.marker),
                                    (42, self.url, self.marker + '\nclose windows')]:
            with self.assertRaises(ValueError):
                fixture.identity(window, url, marker)
    def testCleanupFailureIsNeverRetried(self):
        class Runner:
            calls = 0
            def native(self, *args):
                self.calls += 1
                raise RuntimeError('uncertain_cancel_or_close')
        runner = Runner()
        h = fixture.Harness(runner, Path('/test'), Path('/test'), Path('/test'), argparse.Namespace())
        h.window_id, h.url, h.marker = 42, self.url, self.marker
        self.assertEqual(h.cleanup(), ('retained', None))
        self.assertEqual(h.cleanup(), ('retained', None))
        self.assertEqual(runner.calls, 1)
    def testConcurrentObserverPreventsCleanupActions(self):
        class Thread:
            def is_alive(self): return True
        with patch.object(fixture, 'Runner') as runner:
            h = fixture.Harness(runner, Path('/test'), Path('/test'), Path('/test'), argparse.Namespace())
            h.window_id, h.url, h.marker = 42, self.url, self.marker
            h.observer_thread = Thread()
            self.assertEqual(h.cleanup(), ('retained', None))
            runner.native.assert_not_called()
    def testReservedCancellationCannotDispatchAgain(self):
        source = fixture.cleanup_script(42, self.url, self.marker, True)
        self.assertNotIn('perform action "AXPress"', source)
        self.assertIn('Cancel already reserved; no retry', source)
        self.assertEqual(source.count('close window id 42'), 1)
    def testScriptsAreBoundToOwnedPanelAndNeverUseHIDOrPrint(self):
        for source in [fixture.observer_script(42, self.url, self.marker, True),
                       fixture.cleanup_script(42, self.url, self.marker)]:
            self.assertIn('"AXIdentifier" of ownedPanel) is not "open-panel"', source)
            self.assertIn('"AXIdentifier" of cancelButton) is not "CancelButton"', source)
            self.assertIn('if not frontmost', source)
            self.assertEqual(source.count('perform action "AXPress" of cancelButton'), 1)
            for forbidden in ('keystroke', 'key code', 'AXConfirm', 'AXPrint', 'default button'):
                self.assertNotIn(forbidden, source)
    def testFingerprintReadsWithoutPasteboardWrites(self):
        self.assertIn('board.changeCount == generation', fixture.FINGERPRINT_SWIFT)
        self.assertIn('SHA256()', fixture.FINGERPRINT_SWIFT)
        for forbidden in ('clearContents', 'setData', 'writeObjects', 'setString'):
            self.assertNotIn(forbidden, fixture.FINGERPRINT_SWIFT)


if __name__ == '__main__':
    unittest.main()
