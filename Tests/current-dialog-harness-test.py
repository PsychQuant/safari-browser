#!/usr/bin/env python3
"""Pure safety checks for the #108 live fixture; never contact Safari."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('current_fixture', Path(__file__).with_name('e2e-current-dialog.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureTests(unittest.TestCase):
    nonce = 'owned-confirm-nonce'
    def status(self, **changes):
        value = {'state': 'present', 'window_id': 42, 'messages': [self.nonce], 'reason': None}
        value.update(changes)
        return value
    def listing(self, message=None, buttons=('取消', '好')):
        return ('blocking dialog present\n  message: ' + json.dumps(message or self.nonce)
                + '\n  buttons: ' + ', '.join(json.dumps(b) for b in buttons))
    def testExactNonceAndNamedCancel(self):
        for raw in (self.nonce, 'JavaScript ' + self.nonce):
            self.assertEqual(fixture.expected_cancel(self.status(messages=[raw]), self.listing(raw), 42, self.nonce), (raw, '取消'))
    def testWrongIdentityPrefixUnknownOrAmbiguousButtonsRefuse(self):
        for status in (self.status(window_id=43), self.status(window_id=True), self.status(state='unknown'),
                       self.status(messages=[self.nonce + ' attacker']), self.status(messages=[self.nonce, 'other'])):
            with self.assertRaises(fixture.common.VerificationError):
                fixture.expected_cancel(status, self.listing(), 42, self.nonce)
        for buttons in (('OK',), ('取消', '取消'), ('Cancel all',)):
            with self.assertRaises(fixture.common.VerificationError):
                fixture.expected_cancel(self.status(), self.listing(buttons=buttons), 42, self.nonce)
    def testQueryLatencyAndUnknownCannotPass(self):
        ok = subprocess.CompletedProcess([], 0, json.dumps(self.status()), '')
        fixture.verify_query(ok, 0.5, 'present', 42)
        for outcome, elapsed in ((ok, 3.0), (subprocess.CompletedProcess([], 2, json.dumps(self.status(state='unknown')), ''), 0.1)):
            with self.assertRaises(fixture.common.VerificationError):
                fixture.verify_query(outcome, elapsed, 'present', 42)
    def testIncompleteReasonCannotMasqueradeAsSuccessfulPresence(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(self.status(reason='incomplete')), '')
        with self.assertRaises(fixture.common.VerificationError):
            fixture.verify_query(result, 0.1, 'present', 42)
    def testUnavailableSessionNeverCreatesHarness(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(fixture.tempfile, 'mkdtemp', return_value=directory), \
             patch.object(fixture.common, 'session_preflight', return_value=77), patch.object(fixture, 'Harness') as harness:
            self.assertEqual(fixture.main([]), 77)
            harness.assert_not_called()
    def testCleanupFailureCannotBecomeAcceptance(self):
        class Fake:
            def __init__(self, *args): pass
            def verify_process_group(self): pass
            def exercise(self): return 0
            def cleanup(self): return False
        with tempfile.TemporaryDirectory() as directory, patch.object(fixture.tempfile, 'mkdtemp', return_value=directory), \
             patch.object(fixture.common, 'session_preflight', return_value=0), \
             patch.object(fixture.common, 'image_identifier', return_value='a' * 32), patch.object(fixture, 'Harness', Fake):
            self.assertEqual(fixture.main([]), 1)
    def testUncertainDismissalIsNeverRetried(self):
        with tempfile.TemporaryDirectory() as directory:
            h = fixture.Harness(Path('/missing'), Path('/missing'), 'a' * 32, Path(directory))
            h.dismiss_attempted = True
            with patch.object(h, 'cli') as cli, self.assertRaises(fixture.common.VerificationError):
                h.dismiss_owned()
            cli.assert_not_called()


if __name__ == '__main__':
    unittest.main()
