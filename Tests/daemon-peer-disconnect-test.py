#!/usr/bin/env python3
"""Real private-daemon disconnect regression; never operates Safari or Print."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('owned_process', ROOT / 'scripts/benchmark-performance.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
BINARY = Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve()


class DaemonPeerDisconnectTests(unittest.TestCase):
    def test_exec_known_oversize_never_falls_back(self):
        # An empty exec script is safe even if a broken client falls back:
        # it runs no command and never operates Safari.
        with tempfile.TemporaryDirectory(prefix='sb-size-', dir='/tmp') as directory:
            env = owned.isolated_environment(directory, False)
            env['SAFARI_BROWSER_DAEMON'] = '1'
            script = Path(directory, 'empty.json')
            script.write_text('[]')
            path = str(Path(directory, 'safari-browser-' + env['SAFARI_BROWSER_NAME'] + '.sock'))
            handshake = {'protocol': {'name': 'persistent-daemon',
                'version': {'semver': '1.0.0', 'commit': 'unknown', 'dirty': False, 'vendor': 'source'},
                'maxRequestLineBytes': '1'}}
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(3)
                process = subprocess.Popen([str(BINARY), 'exec', '--script', str(script)], env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(3)
                        connection.sendall(json.dumps(handshake).encode() + b'\n')
                        received = connection.recv(1024)
                    stdout, stderr = process.communicate(timeout=3)
                    self.assertEqual(received, b'', 'exec preflight must send zero request bytes')
                    self.assertNotEqual(process.returncode, 0, 'local fallback would incorrectly succeed')
                    self.assertEqual(stdout, b'')
                    self.assertIn(b'daemon request too large', stderr)
                    self.assertIn(b'no request bytes sent for this RPC', stderr)
                    self.assertNotIn(b'daemon fallback', stderr)
                    self.assertNotIn(str(script).encode(), stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=3)

    def test_peer_disconnects_preserve_service_and_subsequent_requests(self):
        with tempfile.TemporaryDirectory(prefix='sb-peer-', dir='/tmp') as directory:
            env = owned.isolated_environment(directory, False)
            service = owned.Service(str(BINARY), env, 'daemon', 5)
            process = service.process
            path = str(Path(directory, 'safari-browser-' + env['SAFARI_BROWSER_NAME'] + '.sock'))
            request_id = 0

            def read_frame(reader):
                data = reader.readline(65537)
                self.assertTrue(data.endswith(b'\n') and len(data) <= 65536, 'incomplete daemon frame')
                return json.loads(data)

            def connect():
                connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                connection.settimeout(3)
                try:
                    connection.connect(path)
                    return connection
                except BaseException:
                    connection.close()
                    raise

            def request(method, params=None):
                nonlocal request_id
                request_id += 1
                with connect() as connection, connection.makefile('rb') as reader:
                    self.assertEqual(read_frame(reader)['protocol']['name'], 'persistent-daemon')
                    connection.sendall((json.dumps({'method': method, 'params': params or {},
                                                   'requestId': request_id}) + '\n').encode())
                    response = read_frame(reader)
                    self.assertEqual(response['requestId'], request_id)
                    return response

            def assert_available(stage):
                try:
                    self.assertIsNone(owned.observe_exit(process), 'daemon exited after ' + stage)
                    response = request('daemon.status')
                    self.assertEqual(response['result']['pid'], process.pid)
                    self.assertIsNone(owned.observe_exit(process), 'daemon exited during status after ' + stage)
                except (OSError, ValueError, KeyError, AssertionError) as error:
                    outcome = owned.observe_exit(process)
                    self.fail(f'daemon unavailable after {stage}; exit={outcome}; {type(error).__name__}')

            try:
                assert_available('startup')
                # Force peer closure before accept, rather than hoping to win
                # a scheduling race. Only this unreaped owned child is stopped.
                for attempt in range(4):
                    self.assertIsNone(owned.observe_exit(process))
                    os.kill(process.pid, signal.SIGSTOP)
                    try:
                        deadline = time.monotonic() + 3
                        while True:
                            # Consuming a stop notification does not reap the
                            # live child or release its PID ownership.
                            state = os.waitid(os.P_PID, process.pid, os.WSTOPPED | os.WNOHANG)
                            if state is not None:
                                self.assertEqual(state.si_code, os.CLD_STOPPED)
                                break
                            self.assertIsNone(owned.observe_exit(process))
                            self.assertLess(time.monotonic(), deadline, 'owned daemon did not stop')
                            time.sleep(.005)
                        with connect():
                            pass
                    finally:
                        os.kill(process.pid, signal.SIGCONT)
                    assert_available(f'close before accept {attempt}')

                for _ in range(3):
                    with connect() as connection, connection.makefile('rb') as reader:
                        self.assertEqual(read_frame(reader)['protocol']['name'], 'persistent-daemon')
                    assert_available('close after handshake')

                # The socket was protected before the peer disconnected; its
                # unread response must also leave other callers unaffected.
                with connect() as connection, connection.makefile('rb') as reader:
                    read_frame(reader)
                    connection.sendall(b'{"method":"daemon.status","params":{},"requestId":900}\n')
                assert_available('close before reading response')

                self.assertEqual(request('no-such-method')['error']['code'], 'methodNotFound')
                self.assertEqual(request('exec.runScript')['error']['code'], 'handlerError')
                with connect() as connection, connection.makefile('rb') as reader:
                    read_frame(reader)
                    connection.sendall(b'{\n')
                    self.assertEqual(read_frame(reader)['error']['code'], 'parseError')
                assert_available('error replies')

                self.assertIn('result', request('daemon.shutdown'))
                deadline = time.monotonic() + 6
                while owned.observe_exit(process) is None:
                    self.assertLess(time.monotonic(), deadline, 'daemon did not shut down')
                    time.sleep(.01)
                self.assertEqual(owned.observe_exit(process), 0)
            finally:
                self.assertTrue(service.close(), 'owned daemon cleanup failed')
            self.assertIsNotNone(process.returncode)
            self.assertFalse(Path(path).exists(), 'normal shutdown left its socket')
            self.assertFalse(Path(directory, 'safari-browser-' + env['SAFARI_BROWSER_NAME'] + '.pid').exists(),
                             'normal shutdown left its PID record')


if __name__ == '__main__':
    unittest.main()
