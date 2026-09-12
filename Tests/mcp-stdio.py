#!/usr/bin/env python3
"""Real MCP/CLI parity without touching Safari UI or user databases. Refs #110."""
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import uuid
import struct
import tempfile
import subprocess
import threading
import time
import unittest

BIN = str(Path(os.environ.get('SAFARI_BROWSER_BIN', '.build/debug/safari-browser')).resolve())
MODERN = '2026-07-28'
META = {'io.modelcontextprotocol/protocolVersion': MODERN,
        'io.modelcontextprotocol/clientCapabilities': {}}

class Client:
    def __init__(self, *args, binary=BIN):
        self.process = subprocess.Popen([binary, 'mcp', *args], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = queue.Queue()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        self.identifier = 0
    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)
    def send(self, method, params=None, modern=True, identifier=None, notification=False):
        self.identifier += 1
        request = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            request['id'] = self.identifier if identifier is None else identifier
        p = dict(params or {})
        if modern and not notification:
            p['_meta'] = META
        if p:
            request['params'] = p
        self.process.stdin.write(json.dumps(request).encode() + b'\n')
        self.process.stdin.flush()
        return request.get('id')
    def receive(self, timeout=5):
        line = self.lines.get(timeout=timeout)
        if line is None:
            raise AssertionError('server stdout ended: ' + self.process.stderr.read().decode(errors='replace'))
        return json.loads(line)
    def call(self, name, arguments=None, modern=True):
        identifier = self.send('tools/call', {'name': name, 'arguments': arguments or {}}, modern)
        response = self.receive()
        assert response['id'] == identifier, response
        return response
    def close(self):
        if self.process.stderr.closed:
            return b''
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('MCP process did not clean up after EOF')
        self.thread.join(timeout=1)
        stderr = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        return stderr

class MCPStdioTests(unittest.TestCase):
    def setUp(self):
        self.client = Client()
        self.addCleanup(self.client.close)
    def test_modern_full_catalog_and_every_public_help_route(self):
        tools, cursor = [], None
        while True:
            self.client.send('tools/list', {'cursor': cursor} if cursor else {})
            result = self.client.receive()['result']
            self.assertEqual(result['resultType'], 'complete')
            tools.extend(result['tools'])
            cursor = result.get('nextCursor')
            if cursor is None:
                break
        self.assertEqual(len(tools), 76)
        self.assertEqual(len({t['name'] for t in tools}), 76)
        for tool in tools:
            with self.subTest(tool=tool['name']):
                args = {'options': {'help': True}} if 'help' in tool['inputSchema']['properties']['options']['properties'] else {}
                schema = tool['inputSchema']
                for group in ('positionals', 'options'):
                    block = schema['properties'][group]
                    for key in block.get('required', []):
                        item = block['properties'][key]
                        value = True if item['type'] == 'boolean' else ['0'] if item['type'] == 'array' else '0'
                        args.setdefault(group, {})[key] = value
                response = self.client.call(tool['name'], args)
                result = response['result']
                self.assertFalse(result['isError'], result)
                self.assertEqual(result['structuredContent']['exit_code'], 0)
                self.assertTrue(result['structuredContent']['capture_complete'])
                path = '' if tool['name'] == 'safari.help' else ' ' + tool['name'].removeprefix('safari.').replace('.', ' ')
                self.assertIn('USAGE: safari-browser' + path, result['structuredContent']['stdout']['data'])
    def test_actual_async_wait_and_invalid_sync_value_match_cli(self):
        cases = [(['wait', '0'], 'safari.wait', {'positionals': {'milliseconds': '0'}}),
                 (['history', '--limit=invalid'], 'safari.history', {'options': {'limit': 'invalid'}}),
                 (['wait', '--url=a', '--document=2', '--', '0'], 'safari.wait', {'options': {'url': 'a', 'document': '2'}, 'positionals': {'milliseconds': '0'}})]
        for argv, name, args in cases:
            with self.subTest(argv=argv):
                cli = subprocess.run([BIN] + argv, capture_output=True, timeout=5)
                result = self.client.call(name, args)['result']
                captured = result['structuredContent']
                self.assertEqual(captured['exit_code'], cli.returncode)
                self.assertEqual(captured['stdout']['data'].encode(), cli.stdout)
                self.assertEqual(captured['stderr']['data'].encode(), cli.stderr)
                self.assertEqual(result['isError'], cli.returncode != 0)
    def test_exec_stdin_is_separate_and_following_rpc_still_works(self):
        # A malformed script fails before Safari dispatch, proving exec consumed
        # supplied stdin rather than waiting on the MCP request stream.
        result = self.client.call('safari.exec', {'stdin': 'not a valid script'})['result']
        self.assertTrue(result['isError'])
        self.assertNotEqual(result['structuredContent']['exit_code'], 0)
        result = self.client.call('safari.exec', {'stdin': '[{"cmd":"wait","args":["0"]}]'})['result']
        self.assertFalse(result['isError'], result)
        self.assertEqual(json.loads(result['structuredContent']['stdout']['data'])[0]['status'], 'ok')
        self.client.send('ping')
        self.assertEqual(self.client.receive()['result']['resultType'], 'complete')
    def test_cancel_busy_ping_and_eof(self):
        self.client.send('tools/call', {'name': 'safari.wait', 'arguments': {'positionals': {'milliseconds': '30000'}}}, identifier='slow')
        self.client.send('ping', identifier='ping')
        self.assertEqual(self.client.receive()['id'], 'ping')
        busy = self.client.call('safari.wait', {'positionals': {'milliseconds': '0'}})['result']
        self.assertTrue(busy['isError'])
        self.assertIn('not executed', busy['structuredContent']['failure'])
        self.client.send('notifications/cancelled', {'requestId': 'slow'}, notification=True)
        time.sleep(0.15)
        self.client.send('ping', identifier='after')
        self.assertEqual(self.client.receive()['id'], 'after')
        self.client.send('tools/call', {'name': 'safari.wait', 'arguments': {'positionals': {'milliseconds': '30000'}}}, identifier='eof')
        start = time.monotonic()
        self.assertEqual(self.client.close(), b'')
        self.assertLess(time.monotonic() - start, 3)
    def test_legacy_and_malformed_messages(self):
        self.client.send('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}, modern=False)
        self.assertEqual(self.client.receive()['result']['protocolVersion'], '2025-11-25')
        self.client.send('notifications/initialized', notification=True)
        result = self.client.call('safari.wait', {'positionals': {'milliseconds': '0'}}, modern=False)['result']
        self.assertNotIn('resultType', result)
        self.client.process.stdin.write(b'{bad}\n')
        self.client.process.stdin.flush()
        self.assertEqual(self.client.receive()['error']['code'], -32700)
        self.client.send('ping', identifier=True)
        self.assertEqual(self.client.receive()['error']['code'], -32600)
        self.client.send('server/discover')
        self.assertIn(MODERN, self.client.receive()['result']['supportedVersions'])
    def test_atomic_executable_replacement_refuses_new_image(self):
        # Modify only LC_UUID in a private copy, then re-sign before replacement.
        # The loaded server still sees the old UUID; its next worker sees the new one.
        with tempfile.TemporaryDirectory(prefix='safari-mcp-image-') as directory:
            executable = Path(directory) / 'safari-browser'
            replacement = Path(directory) / 'replacement'
            shutil.copy2(BIN, executable)
            client = Client(binary=str(executable))
            try:
                client.send('ping')
                self.assertIn('result', client.receive())
                data = bytearray(executable.read_bytes())
                self.assertEqual(struct.unpack_from('<I', data)[0], 0xfeedfacf)
                count = struct.unpack_from('<I', data, 16)[0]
                offset, found = 32, False
                for _ in range(count):
                    command, size = struct.unpack_from('<II', data, offset)
                    if command == 0x1b:
                        data[offset + 8] ^= 1
                        found = True
                        break
                    offset += size
                self.assertTrue(found)
                replacement.write_bytes(data)
                replacement.chmod(0o755)
                signed = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(replacement)], capture_output=True, timeout=30)
                self.assertEqual(signed.returncode, 0, signed.stderr)
                os.replace(replacement, executable)
                result = client.call('safari.wait', {'positionals': {'milliseconds': '0'}})['result']
                self.assertTrue(result['isError'])
                self.assertIn('executable changed', result['structuredContent']['stderr']['data'])
                self.assertIn('not executed', result['structuredContent']['stderr']['data'])
                client.send('ping')
                self.assertIn('result', client.receive())
            finally:
                client.close()

    def test_backpressured_output_does_not_block_eof_or_cancellation(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                process = subprocess.Popen([BIN, 'mcp', '--timeout=2'], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                def send(identifier, method, params, notification=False):
                    request = {'jsonrpc': '2.0', 'method': method, 'params': dict(params)}
                    if not notification:
                        request['id'] = identifier
                        request['params']['_meta'] = META
                    process.stdin.write(json.dumps(request).encode() + b'\n')
                    process.stdin.flush()
                try:
                    send('slow', 'tools/call', {'name': 'safari.wait', 'arguments': {'positionals': {'milliseconds': '30000'}}})
                    # Wait until the real worker exists, so cancellation cannot
                    # accidentally pass by cancelling a call before it starts.
                    deadline = time.monotonic() + 1
                    while time.monotonic() < deadline:
                        child = subprocess.run(['/usr/bin/pgrep', '-P', str(process.pid)], capture_output=True)
                        if child.returncode == 0:
                            break
                        time.sleep(0.01)
                    self.assertEqual(child.returncode, 0, 'worker did not start')
                    send('x' * 262144, 'ping', {})
                    if cancel:
                        send(None, 'notifications/cancelled', {'requestId': 'slow'}, notification=True)
                        deadline = time.monotonic() + 0.8
                        while time.monotonic() < deadline:
                            child = subprocess.run(['/usr/bin/pgrep', '-P', str(process.pid)], capture_output=True)
                            if child.returncode == 1:
                                break
                            time.sleep(0.01)
                        self.assertEqual(child.returncode, 1, 'cancel blocked behind stdout')
                    process.stdin.close()
                    process.wait(timeout=1)
                finally:
                    # On RED, allow the bounded worker timeout to clean up first.
                    if process.poll() is None:
                        time.sleep(2.2)
                        process.kill()
                        process.wait()
                    if not process.stdin.closed:
                        process.stdin.close()
                    process.stdout.close()
                    process.stderr.close()

    @staticmethod
    def process_info(pid):
        result = subprocess.run(['/bin/ps', '-o', 'pid=,ppid=,pgid=,stat=,command=', '-p', str(pid)], capture_output=True, text=True)
        fields = result.stdout.strip().split(None, 4)
        if result.returncode or len(fields) != 5:
            return None
        return (int(fields[0]), int(fields[1]), int(fields[2]), fields[3], fields[4])

    def test_nested_exec_children_stay_owned_through_cancel_and_eof(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                client = Client('--timeout=2')
                grandchild = None
                try:
                    client.send('tools/call', {'name': 'safari.exec', 'arguments': {'stdin': '[{"cmd":"wait","args":["30000"]}]'}}, identifier='nested')
                    deadline = time.monotonic() + 1
                    while time.monotonic() < deadline:
                        child = subprocess.run(['/usr/bin/pgrep', '-P', str(client.process.pid)], capture_output=True, text=True)
                        if child.stdout.strip():
                            worker = int(child.stdout.split()[0])
                            nested = subprocess.run(['/usr/bin/pgrep', '-P', str(worker)], capture_output=True, text=True)
                            if nested.stdout.strip():
                                grandchild = int(nested.stdout.split()[0])
                                info = self.process_info(grandchild)
                                if info and 'wait 30000' in info[4]:
                                    break
                        time.sleep(0.01)
                    self.assertIsNotNone(grandchild, 'nested CLI did not start')
                    self.assertEqual(info[2], worker, 'nested CLI escaped worker group')
                    time.sleep(0.05)
                    if cancel:
                        client.send('notifications/cancelled', {'requestId': 'nested'}, notification=True)
                    else:
                        client.close()
                    deadline = time.monotonic() + 0.8
                    while time.monotonic() < deadline:
                        info = self.process_info(grandchild)
                        if info is None or info[3].startswith('Z'):
                            break
                        time.sleep(0.01)
                    self.assertTrue(info is None or info[3].startswith('Z'), 'nested CLI survived cancellation/EOF')
                finally:
                    client.close()
                    if grandchild:
                        info = self.process_info(grandchild)
                        if info and BIN in info[4] and 'wait 30000' in info[4]:
                            try:
                                os.kill(grandchild, signal.SIGKILL)
                            except ProcessLookupError:
                                pass

    def test_explicit_daemon_can_detach_and_is_stopped_after_test(self):
        with tempfile.TemporaryDirectory(prefix='mcp-', dir='/tmp') as directory:
            name = 'mcp-' + uuid.uuid4().hex[:8]
            options = {'name': name, 'socket-dir': directory}
            daemon_pid = None
            try:
                result = self.client.call('safari.daemon.start', {'options': options})['result']
                self.assertFalse(result['isError'], result)
                message = result['structuredContent']['stdout']['data']
                daemon_pid = int(message.split('(pid ')[1].split(')')[0])
                info = self.process_info(daemon_pid)
                self.assertIsNotNone(info)
                self.assertEqual(info[2], daemon_pid, 'persistent daemon must detach from its worker')
                result = self.client.call('safari.daemon.status', {'options': options})['result']
                self.assertFalse(result['isError'], result)
            finally:
                stopped = subprocess.run([BIN, 'daemon', 'stop', '--name', name, '--socket-dir', directory], capture_output=True, timeout=8)
                if daemon_pid:
                    info = self.process_info(daemon_pid)
                    if info and name in info[4] and '__serve' in info[4]:
                        try:
                            os.kill(daemon_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                self.assertEqual(stopped.returncode, 0, stopped.stderr)

    def test_worker_identity_guard_and_hidden_entry(self):
        env = dict(os.environ, SAFARI_BROWSER_MCP_IMAGE_ID='different-build', SAFARI_BROWSER_MCP_DIRECT='1')
        child = subprocess.run([BIN, '__mcp-exec', 'wait', '0'], env=env, capture_output=True, timeout=5)
        self.assertNotEqual(child.returncode, 0)
        self.assertIn(b'executable changed', child.stderr)
        env.pop('SAFARI_BROWSER_MCP_IMAGE_ID')
        child = subprocess.run([BIN, '__mcp-exec', 'wait', '0'], env=env, capture_output=True, timeout=5)
        self.assertNotEqual(child.returncode, 0)
        self.assertIn(b'internal MCP worker', child.stderr)

if __name__ == '__main__':
    unittest.main()
