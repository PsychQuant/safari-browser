#!/usr/bin/env python3
"""#141: an exit-zero child without a completed suite is not a green run."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
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

    # #343: a test that never finishes must not hold the run forever.
    def run_stalling(self, program, limit='1'):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'swift'
            fake.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys,time\n' + program)
            fake.chmod(0o755)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ['PATH'], UNIT_TEST_STALL_SECONDS=limit, MARK=str(Path(tmp) / 'pids'))
            started = time.monotonic()
            result = subprocess.run(['python3', str(RUNNER)], env=env, capture_output=True, text=True, timeout=60)
            pids = (Path(tmp) / 'pids').read_text().split() if (Path(tmp) / 'pids').exists() else []
            return result, time.monotonic() - started, pids

    HANGS = ("print(\"Test Case '-[S.A testFine]' started.\", flush=True)\n"
             "print(\"Test Case '-[S.A testFine]' passed (0.001 seconds).\", flush=True)\n"
             "print(\"Test Case '-[S.B testHung]' started.\", flush=True)\n"
             "worker = subprocess.Popen(['sleep', '50'])\n"
             "open(os.environ['MARK'], 'w').write(f'{os.getpid()} {worker.pid}')\n"
             "time.sleep(50)\n")

    def test_a_silent_run_stops_and_names_the_test(self):
        result, took, pids = self.run_stalling(self.HANGS)
        self.assertEqual(result.returncode, 1)
        self.assertLess(took, 20)
        self.assertIn('testHung', result.stderr)
        self.assertNotIn('testFine', result.stderr)

    def test_the_stopped_run_leaves_no_process(self):
        _, _, pids = self.run_stalling(self.HANGS)
        self.assertEqual(len(pids), 2)
        time.sleep(0.5)
        for pid in pids:
            with self.assertRaises(ProcessLookupError, msg=pid):
                os.kill(int(pid), 0)

    # The real xctest has a process group of its own, and a signal to swift-test's group misses it.
    IN_ITS_OWN_GROUP_IGNORING_SIGNALS = (
        "worker = subprocess.Popen([sys.executable, '-c', 'import signal,time\\n'\n"
        "    'for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(s, signal.SIG_IGN)\\n'\n"
        "    'time.sleep(50)'], start_new_session=True)\n"
        "open(os.environ['MARK'], 'w').write(f'{os.getpid()} {worker.pid}')\n"
        "print(\"Test Case '-[S.B testHung]' started.\", flush=True)\n"
        "time.sleep(50)\n")

    def test_a_test_process_in_its_own_group_is_stopped_too(self):
        result, _, pids = self.run_stalling(self.IN_ITS_OWN_GROUP_IGNORING_SIGNALS)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(pids), 2)
        time.sleep(0.5)
        for pid in pids:
            with self.assertRaises(ProcessLookupError, msg=pid):
                os.kill(int(pid), 0)

    def test_the_run_is_asked_to_stop_before_it_is_killed(self):
        # swift-test passes SIGINT on to the test process and can finish its own output.
        result, _, pids = self.run_stalling(
            "import signal\n"
            "def asked(*_):\n"
            "    open(os.environ['MARK'], 'w').write('asked')\n"
            "    os._exit(1)\n"
            "signal.signal(signal.SIGINT, asked)\n"
            "time.sleep(50)\n")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(pids, ['asked'])

    def test_output_goes_to_a_terminal_so_it_is_not_held_back(self):
        result, _, _ = self.run_stalling(f'assert os.isatty(1) and os.isatty(2)\nprint({COMPLETE!r}, flush=True)\n', limit='5')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_process_that_closes_its_output_and_stays_is_stopped(self):
        result, took, _ = self.run_stalling('os.close(1)\nos.close(2)\ntime.sleep(50)\n')
        self.assertEqual(result.returncode, 1)
        self.assertLess(took, 20)

    def test_a_process_left_holding_the_output_does_not_hold_the_run(self):
        result, took, _ = self.run_stalling(
            f"subprocess.Popen(['sleep', '20'])\nprint({COMPLETE!r}, flush=True)\n", limit='15')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(took, 12)

    def test_two_tests_at_once_are_tracked_by_name(self):
        result, _, _ = self.run_stalling(
            "print(\"Test Case '-[S.A testA]' started.\", flush=True)\n"
            "print(\"Test Case '-[S.B testB]' started.\", flush=True)\n"
            "print(\"Test Case '-[S.A testA]' passed (0.001 seconds).\", flush=True)\n"
            "time.sleep(50)\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn('still running: -[S.B testB]', result.stderr)
        self.assertNotIn('testA', result.stderr)

    def test_a_failed_or_skipped_test_is_finished_too(self):
        for word in ('failed', 'skipped'):
            result, _, _ = self.run_stalling(
                "print(\"Test Case '-[S.A testA]' started.\", flush=True)\n"
                f"print(\"Test Case '-[S.A testA]' {word} (0.001 seconds).\", flush=True)\n"
                "time.sleep(50)\n")
            self.assertIn('nothing was running', result.stderr, word)

    def test_swift_testing_is_seen(self):
        result, _, _ = self.run_stalling(
            'print("\\u25c7 Test slowThing() started.", flush=True)\ntime.sleep(50)\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('still running: slowThing()', result.stderr)

    def test_swift_testing_announcing_the_run_is_not_a_test(self):
        result, _, _ = self.run_stalling(
            'print("\\u25c7 Test run started.", flush=True)\nprint("\\u25c7 Test slowThing() started.", flush=True)\ntime.sleep(50)\n')
        self.assertIn('still running: slowThing().', result.stderr)

    def test_output_in_front_of_the_line_does_not_hide_a_test(self):
        result, _, _ = self.run_stalling(
            "print(\"dots...Test Case '-[S.A testA]' started.\", flush=True)\ntime.sleep(50)\n")
        self.assertIn('still running: -[S.A testA]', result.stderr)

    def test_undecodable_output_is_not_mistaken_for_silence(self):
        result, took, _ = self.run_stalling(
            f"os.write(1, b'\\xff\\xfe\\n')\nprint({COMPLETE!r}, flush=True)\n", limit='15')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(took, 10)

    def signalled(self, sig):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'swift'
            fake.write_text('#!/usr/bin/env python3\nimport os,subprocess,time\n' + self.HANGS.split('#')[0])
            fake.chmod(0o755)
            mark = Path(tmp) / 'pids'
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ['PATH'], UNIT_TEST_STALL_SECONDS='60', MARK=str(mark))
            runner = subprocess.Popen(['python3', str(RUNNER)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                if mark.exists() and mark.read_text():
                    break
                time.sleep(0.1)
            pids = mark.read_text().split()
            time.sleep(0.5)
            runner.send_signal(sig)
            code = runner.wait(timeout=20)
            time.sleep(0.5)
            for pid in pids:
                with self.assertRaises(ProcessLookupError, msg=pid):
                    os.kill(int(pid), 0)
            return code

    def test_signals_to_the_runner_take_the_run_down(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.assertEqual(self.signalled(sig), 130, sig)

    def test_silence_between_tests_names_the_last_one_finished(self):
        result, _, _ = self.run_stalling(
            "print(\"Test Case '-[S.A testFine]' started.\", flush=True)\n"
            "print(\"Test Case '-[S.A testFine]' passed (0.001 seconds).\", flush=True)\n"
            "time.sleep(50)\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn('nothing was running', result.stderr)
        self.assertIn('testFine', result.stderr)

    def test_silence_before_any_test_says_so(self):
        result, _, _ = self.run_stalling('time.sleep(50)\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no test had started', result.stderr)

    def test_quiet_under_the_limit_is_not_a_stall(self):
        result, _, _ = self.run_stalling(
            f'time.sleep(0.3)\nprint({COMPLETE!r}, flush=True)\ntime.sleep(0.3)\n', limit='5')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_limit_that_is_not_a_positive_number_is_refused(self):
        for limit in ('0', '-1', 'soon', 'inf', 'nan', '9999999999'):
            result, _, _ = self.run_stalling('print("should not run", flush=True)\n', limit=limit)
            self.assertEqual(result.returncode, 2, limit)
            self.assertIn('UNIT_TEST_STALL_SECONDS', result.stderr)

if __name__=='__main__': unittest.main()
