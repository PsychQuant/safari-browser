#!/usr/bin/env python3
"""Real CLI timing contract checks; no Safari, dialogs, or daemon startup."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve()
PREFIX = '[safari-browser timing] '

class TraceCLITests(unittest.TestCase):
    def invoke(self, args, flag):
        env = dict(os.environ)
        for key in ['SAFARI_BROWSER_TRACE_TIMING', 'SAFARI_BROWSER_DAEMON', 'SAFARI_BROWSER_MCP_DIRECT', 'SAFARI_BROWSER_MCP_IMAGE_ID']:
            env.pop(key, None)
        env['SAFARI_BROWSER_NAME'] = 'trace-test-' + uuid.uuid4().hex
        if flag is not None:
            env['SAFARI_BROWSER_TRACE_TIMING'] = flag
        return subprocess.run([str(BINARY), *args], env=env, capture_output=True, text=True, timeout=10)

    def summary(self, result):
        lines = [line[len(PREFIX):] for line in result.stderr.splitlines() if line.startswith(PREFIX)]
        self.assertEqual(len(lines), 1, result.stderr)
        value = json.loads(lines[0])
        self.assertEqual(value['schemaVersion'], 1)
        self.assertEqual(str(uuid.UUID(value['requestID'])), value['requestID'].lower())
        self.assertGreaterEqual(value['totalNanoseconds'], 0)
        self.assertLessEqual(len(value['spans']), 64)
        self.assertIn('command', [span['phase'] for span in value['spans']])
        return value

    def test_off_does_not_emit_or_change_output(self):
        for flag in [None, '0', 'true']:
            with self.subTest(flag=flag):
                result = self.invoke(['wait', '0'], flag)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_success_has_own_summary_without_stdout_changes(self):
        a = self.invoke(['wait', '0'], '1')
        b = self.invoke(['wait', '0'], '1')
        self.assertEqual((a.returncode, a.stdout), (0, ''))
        x, y = self.summary(a), self.summary(b)
        self.assertEqual(x['status'], 'ok')
        self.assertNotEqual(x['requestID'], y['requestID'])

    def test_error_preserved_without_argument_in_summary(self):
        marker = '--private-sentinel-should-not-enter-trace'
        plain = self.invoke([marker], None)
        traced = self.invoke([marker], '1')
        self.assertEqual(traced.returncode, plain.returncode)
        self.assertNotEqual(traced.returncode, 0)
        self.assertEqual(traced.stdout, plain.stdout)
        summary = self.summary(traced)
        self.assertEqual(summary['status'], 'error')
        self.assertNotIn(marker, json.dumps(summary))
        filtered = '\n'.join(line for line in traced.stderr.splitlines() if not line.startswith(PREFIX)) + '\n'
        self.assertEqual(filtered, plain.stderr)

    def test_exec_traces_identify_parent_and_child_processes(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith('SAFARI_BROWSER_')}
        env.update(SAFARI_BROWSER_TRACE_TIMING='1', SAFARI_BROWSER_NAME='trace-exec-' + uuid.uuid4().hex)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as script:
            json.dump([{'cmd': 'wait', 'args': ['0']}, {'cmd': 'wait', 'args': ['0']}], script)
            script.flush()
            process = subprocess.Popen([str(BINARY), 'exec', '--script', script.name], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            output, errors = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)
        traces = [json.loads(line[len(PREFIX):]) for line in errors.splitlines() if line.startswith(PREFIX)]
        self.assertEqual(len(traces), 3)
        roots = [trace for trace in traces if trace.get('processID') == process.pid]
        self.assertEqual(len(roots), 1, 'root must be identifiable without guessing by duration or order')
        self.assertEqual(len({trace['processID'] for trace in traces}), 3)

    def test_help_remains_success(self):
        plain = self.invoke(['--help'], None)
        traced = self.invoke(['--help'], '1')
        self.assertEqual((traced.returncode, traced.stdout), (plain.returncode, plain.stdout))
        self.assertEqual(self.summary(traced)['status'], 'ok')

if __name__ == '__main__':
    unittest.main()
