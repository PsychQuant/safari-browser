#!/usr/bin/env python3
"""#141: an exit-zero child without a completed suite is not a green run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[1] / 'scripts/run-unit-tests.py'
COMPLETE = "Test Suite 'All tests' passed at 2026-09-12 01:00:00.\n\t Executed 12 tests, with 0 failures (0 unexpected) in 1.000 (1.001) seconds\n"

class UnitRunnerTests(unittest.TestCase):
    def run_fake(self, output, code=0):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'swift'
            fake.write_text('#!/usr/bin/env python3\nimport os,sys\nassert sys.argv[1] == "test"\nassert os.environ["SKIP_E2E"] == "1"\nprint('+repr(output)+')\nsys.exit('+str(code)+')\n')
            fake.chmod(0o755)
            return subprocess.run(['python3',str(RUNNER)],env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH']),text=True,capture_output=True)

    def test_complete_suite_passes(self):
        self.assertEqual(self.run_fake(COMPLETE).returncode,0)

    def test_truncated_exit_zero_fails(self):
        result=self.run_fake("Test Suite 'All tests' started at date\nTest Case 'testOne' passed (0.001 seconds).")
        self.assertNotEqual(result.returncode,0)
        self.assertIn('completion',result.stderr)

    def test_subsuite_alone_cannot_prove_completion(self):
        self.assertNotEqual(self.run_fake(COMPLETE.replace('All tests','OneTests')).returncode,0)

    def test_nonzero_exit_overrides_completion(self):
        self.assertNotEqual(self.run_fake(COMPLETE,1).returncode,0)

    def test_zero_tests_fails(self):
        self.assertNotEqual(self.run_fake(COMPLETE.replace('12 tests','0 tests')).returncode,0)

    def test_failed_summary_fails_even_with_exit_zero(self):
        self.assertNotEqual(self.run_fake(COMPLETE.replace('0 failures','1 failures')).returncode,0)

    def test_selected_suite_is_complete(self):
        self.assertEqual(self.run_fake(COMPLETE.replace('All tests','Selected tests')).returncode,0)

if __name__=='__main__': unittest.main()
