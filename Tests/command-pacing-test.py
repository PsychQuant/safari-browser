#!/usr/bin/env python3
"""Owned non-GUI pacing integration: no Safari, user databases, or real daemon."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BIN = str(Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve())
spec = importlib.util.spec_from_file_location('mcp_fixture', ROOT / 'Tests/mcp-stdio.py')
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


def environment(directory, mode='cauchy'):
    env = {key: value for key, value in os.environ.items() if not key.startswith('SAFARI_BROWSER_')}
    env.update(TMPDIR=str(directory) + '/', SAFARI_BROWSER_NAME='pace', SAFARI_BROWSER_PACING=mode,
               SAFARI_BROWSER_PACING_MIN_MS='80', SAFARI_BROWSER_PACING_MEDIAN_MS='100',
               SAFARI_BROWSER_PACING_MAX_MS='120')
    return env


class OwnedBatchDaemon:
    """Only records the RPC and returns a literal; never executes script content."""
    def __init__(self, directory):
        self.path = str(Path(directory, 'safari-browser-pace.sock'))
        self.requests = []
        self.errors = []
        self.stop = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(4)
        self.listener.settimeout(.05)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                with connection, connection.makefile('rb') as reader:
                    connection.settimeout(2)
                    handshake = {'protocol': {'name': 'persistent-daemon', 'version': {
                        'semver': '1.0.0', 'commit': 'unknown', 'dirty': False, 'vendor': 'source'}}}
                    connection.sendall(json.dumps(handshake).encode() + b'\n')
                    raw = reader.readline(65537)
                    if not raw:
                        continue
                    request = json.loads(raw)
                    self.requests.append(request)
                    result = [{'step': index, 'status': 'ok', 'value': 'owned-batch'} for index in range(3)]
                    response = {'requestId': request['requestId'], 'result': {'results': json.dumps(result)}}
                    connection.sendall(json.dumps(response).encode() + b'\n')
            except Exception as error:
                self.errors.append(repr(error))

    def close(self):
        self.stop.set()
        self.thread.join(timeout=3)
        self.listener.close()
        if self.thread.is_alive():
            raise AssertionError('Owned fake daemon did not stop')
        if self.errors:
            raise AssertionError(self.errors)


class CommandPacingTests(unittest.TestCase):
    def test_hidden_default_tab_runtime_failure_is_paced(self):
        # Without --profile, this runtime-invalid number is rejected before
        # any Safari call. It exercises the real hidden default leaf safely.
        with tempfile.TemporaryDirectory(prefix='sb-pace-', dir='/tmp') as directory:
            for arguments in [['tab', 'notanumber'], ['tab', 'switch', 'notanumber']]:
                with self.subTest(arguments=arguments):
                    invalid = subprocess.run([BIN] + arguments, env=environment(directory, 'owned-invalid-mode'),
                                             capture_output=True, timeout=5)
                    self.assertEqual(invalid.returncode, 64)
                    self.assertIn(b'SAFARI_BROWSER_PACING', invalid.stderr)
                    self.assertNotIn(b'Expected a tab number', invalid.stderr)
                    start = time.monotonic()
                    result = subprocess.run([BIN] + arguments, env=environment(directory), capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 64)
                    self.assertIn(b"Expected a tab number or 'new'", result.stderr)
                    self.assertGreaterEqual(time.monotonic() - start, .07)

    def test_paced_exec_selects_steps_before_any_batch_rpc(self):
        with tempfile.TemporaryDirectory(prefix='sb-pace-', dir='/tmp') as directory:
            missing = str(Path(directory, 'owned-does-not-exist.js'))
            # `js --file` is not a shape the in-process dispatcher runs exactly as the CLI does
            # (#220), so this script always runs as children; each child fails at the missing
            # file before it could touch Safari. That makes it the fixture for the paced mode.
            steps = [
                {'cmd': 'js', 'args': ['--file', missing], 'onError': 'continue'},
                {'cmd': 'js', 'args': ['--file', missing], 'onError': 'continue'},
                {'cmd': 'js', 'args': ['--file', missing], 'if': '$absent exists'},
            ]
            source = Path(directory, 'steps.json')
            source.write_text(json.dumps(steps))
            # Every step has a shape the in-process dispatcher honours, so with pacing off the whole
            # script is one batch RPC; nothing runs as a child, so Safari is never touched.
            batchable = Path(directory, 'batchable.json')
            batchable.write_text(json.dumps([
                {'cmd': 'get url'}, {'cmd': 'get title'}, {'cmd': 'get url', 'if': '$absent exists'},
            ]))
            # The same in-process shapes, every step guarded by a false `if`: it routes to the daemon
            # exactly when `run()` passes the wrong pacing or opt-in to the route, and when it does
            # not, the children run nothing, so Safari is never touched.
            guarded = Path(directory, 'guarded.json')
            guarded.write_text(json.dumps([
                {'cmd': 'get url', 'if': '$absent exists'}, {'cmd': 'get title', 'if': '$absent exists'},
                {'cmd': 'js', 'args': ['1+1'], 'if': '$absent exists'},
            ]))
            daemon = OwnedBatchDaemon(directory)
            try:
                env = environment(directory, 'cauchy')
                env['SAFARI_BROWSER_DAEMON'] = '1'
                with self.subTest(mode='cauchy, a script that would otherwise be one batch'):
                    # `run()` must read the pacing setting and hand it to the route: with pacing on
                    # this script is NOT sent (a `pacingEnabled: false` in `run()` sends it).
                    before = len(daemon.requests)
                    result = subprocess.run([BIN, 'exec', '--script', str(guarded)], env=env,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual([row['status'] for row in json.loads(result.stdout)], ['skipped'] * 3)
                    self.assertEqual(len(daemon.requests) - before, 0, 'Paced exec must not send batch RPC')
                with self.subTest(mode='no daemon signal at all'):
                    # `run()` must read the daemon opt-in: with none of the three signals set, nothing
                    # connects and nothing says `daemon fallback` (a `daemonOptedIn: true` would try).
                    other = environment(directory, 'off')
                    other['SAFARI_BROWSER_NAME'] = 'nobody'
                    before = len(daemon.requests)
                    result = subprocess.run([BIN, 'exec', '--script', str(guarded)], env=other,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual([row['status'] for row in json.loads(result.stdout)], ['skipped'] * 3)
                    self.assertEqual(len(daemon.requests) - before, 0)
                    self.assertNotIn(b'daemon fallback', result.stderr)
                with self.subTest(mode='cauchy'):
                    before = len(daemon.requests)
                    start = time.monotonic()
                    result = subprocess.run([BIN, 'exec', '--script', str(source)], env=env,
                                            capture_output=True, timeout=5)
                    elapsed = time.monotonic() - start
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    output = json.loads(result.stdout)
                    self.assertEqual(len(daemon.requests) - before, 0, 'Paced exec must not send batch RPC')
                    self.assertEqual([row['status'] for row in output], ['error', 'error', 'skipped'])
                    self.assertGreaterEqual(elapsed, .14, 'Two eligible child commands must each wait')
                    self.assertNotIn(b'daemon fallback', result.stderr)
                env = environment(directory, 'off')
                env['SAFARI_BROWSER_DAEMON'] = '1'
                with self.subTest(mode='off, batchable script'):
                    before = len(daemon.requests)
                    result = subprocess.run([BIN, 'exec', '--script', str(batchable)], env=env,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    output = json.loads(result.stdout)
                    self.assertEqual(len(daemon.requests) - before, 1)
                    self.assertEqual(daemon.requests[-1]['method'], 'exec.runScript')
                    self.assertEqual([row['value'] for row in output[:2]], ['owned-batch'] * 2)
                with self.subTest(mode='off, a step the dispatcher would misread'):
                    # The pre-flight looks at the arguments, not just the command (#220): one
                    # step it cannot honour sends the whole script to the subprocess path.
                    before = len(daemon.requests)
                    result = subprocess.run([BIN, 'exec', '--script', str(source)], env=env,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    output = json.loads(result.stdout)
                    self.assertEqual(len(daemon.requests) - before, 0, 'no batch RPC for a script with `js --file`')
                    self.assertEqual([row['status'] for row in output], ['error', 'error', 'skipped'])
            finally:
                daemon.close()

    def test_runtime_error_pacing_matches_standalone_and_both_mcp_modes(self):
        with tempfile.TemporaryDirectory(prefix='sb-pace-', dir='/tmp') as directory:
            env = environment(directory)
            start = time.monotonic()
            direct = subprocess.run([BIN, 'history', '--limit', '0'], env=env, capture_output=True, timeout=5)
            self.assertEqual(direct.returncode, 64)
            self.assertIn(b'--limit must be a positive integer', direct.stderr)
            self.assertGreaterEqual(time.monotonic() - start, .07)
            for mode in ['persistent', 'isolated']:
                with self.subTest(mode=mode):
                    client = mcp.Client('--timeout=3', binary=BIN, worker_mode=mode, environment=env)
                    try:
                        client.send('ping')
                        self.assertEqual(client.receive()['result']['resultType'], 'complete')
                        start = time.monotonic()
                        result = client.call('safari.history', {'options': {'limit': '0'}})['result']
                        elapsed = time.monotonic() - start
                        self.assertEqual(result['structuredContent']['exit_code'], 64, result)
                        self.assertIn('--limit must be a positive integer', result['structuredContent']['stderr']['data'])
                        self.assertGreaterEqual(elapsed, .07)
                    finally:
                        client.close()

    def test_mcp_timeout_includes_pacing_and_explicit_wait_still_recovers(self):
        with tempfile.TemporaryDirectory(prefix='sb-pace-', dir='/tmp') as directory:
            env = environment(directory)
            env.update(SAFARI_BROWSER_PACING_MIN_MS='800', SAFARI_BROWSER_PACING_MEDIAN_MS='900',
                       SAFARI_BROWSER_PACING_MAX_MS='1000')
            for mode in ['persistent', 'isolated']:
                with self.subTest(mode=mode):
                    client = mcp.Client('--timeout=.3', binary=BIN, worker_mode=mode, environment=env)
                    try:
                        start = time.monotonic()
                        result = client.call('safari.history', {'options': {'limit': '0'}})['result']
                        self.assertTrue(result['isError'])
                        self.assertIn('timed out', result['structuredContent']['failure'])
                        self.assertLess(time.monotonic() - start, 2, 'Pacing must not extend the existing host deadline')
                        following = client.call('safari.wait', {'positionals': {'milliseconds': '0'}})['result']
                        self.assertFalse(following['isError'], following)
                        self.assertEqual(following['structuredContent']['exit_code'], 0)
                    finally:
                        client.close()

    def test_invalid_policy_does_not_block_mcp_host_or_help(self):
        with tempfile.TemporaryDirectory(prefix='sb-pace-', dir='/tmp') as directory:
            env = environment(directory, 'owned-invalid-mode')
            for mode in ['persistent', 'isolated']:
                with self.subTest(mode=mode):
                    client = mcp.Client('--timeout=3', binary=BIN, worker_mode=mode, environment=env)
                    try:
                        client.send('ping')
                        self.assertEqual(client.receive()['result']['resultType'], 'complete')
                        help_result = client.call('safari.history', {'options': {'help': True}})['result']
                        self.assertFalse(help_result['isError'], help_result)
                        self.assertIn('USAGE: safari-browser history', help_result['structuredContent']['stdout']['data'])
                        failure = client.call('safari.history', {'options': {'limit': '0'}})['result']
                        self.assertEqual(failure['structuredContent']['exit_code'], 64)
                        self.assertIn('SAFARI_BROWSER_PACING', failure['structuredContent']['stderr']['data'])
                        self.assertNotIn('--limit must', failure['structuredContent']['stderr']['data'])
                    finally:
                        client.close()


if __name__ == '__main__':
    unittest.main()
