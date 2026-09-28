#!/usr/bin/env python3
"""Actual MCP TERM/grace/host-death regression, using only owned wait fixtures."""
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = str(Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve())
spec = importlib.util.spec_from_file_location('mcp_fixture', ROOT / 'Tests/mcp-stdio.py')
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


def uuid_offset(data):
    # Like the existing binary-replacement fixture, this targets the native
    # thin SwiftPM test product, never modifies an installed executable.
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise AssertionError('Expected native 64-bit Mach-O fixture')
    count, size = struct.unpack_from('<II', data, 16)
    offset, end = 32, 32 + size
    if end > len(data):
        raise AssertionError('Truncated fixture header')
    for _ in range(count):
        if offset + 8 > end:
            raise AssertionError('Invalid fixture command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > end:
            raise AssertionError('Invalid fixture command size')
        if command == 0x1b and length >= 24:
            return offset + 8
        offset += length
    raise AssertionError('Missing fixture UUID')


def process_table():
    rows = {}
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat='], text=True, timeout=3)
    for line in output.splitlines():
        pid, parent, group, state = line.split()
        rows[int(pid)] = (int(parent), int(group), state)
    return rows


class MCPTerminationTests(unittest.TestCase):
    def test_host_death_after_real_group_term_keeps_lifetime_protection(self):
        with tempfile.TemporaryDirectory(prefix='mcp-term-', dir='/tmp') as directory:
            directory = Path(directory)
            library = directory / 'owned-termination.dylib'
            subprocess.run(['xcrun', 'clang', '-dynamiclib', '-Wno-deprecated-declarations',
                            str(ROOT / 'Tests/Fixtures/MCPHostTerminationInterpose.c'), '-o', str(library)],
                           check=True, capture_output=True, timeout=30)
            # dyld places an inserted library at image index0. Align ONLY this
            # owned instrumentation UUID with the unchanged CLI so its existing
            # build-consistency check still describes the actual product image.
            # UUID is not authentication; no installed binary/TCC is changed.
            executable = Path(BIN).read_bytes()
            data = bytearray(library.read_bytes())
            source, destination = uuid_offset(executable), uuid_offset(data)
            data[destination:destination + 16] = executable[source:source + 16]
            library.write_bytes(data)
            subprocess.run(['codesign', '--force', '--sign', '-', str(library)],
                           check=True, capture_output=True, timeout=20)
            for mode, large in [('persistent', False), ('isolated', False), ('persistent', True)]:
                with self.subTest(mode=mode, large=large):
                    marker = directory / f'{mode}-{large}.events'
                    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library),
                               OWNED_TERM_RECORD=str(marker), OWNED_STOP_AFTER_TERM='1')
                    client = mcp.Client('--timeout=10', binary=BIN, worker_mode=mode, environment=env)
                    observed = set()
                    try:
                        value = ('0' * (os.sysconf('SC_ARG_MAX') // 2 + 4096) if large else '') + '5000'
                        client.send('tools/call', {'name': 'safari.wait', 'arguments': {'positionals': {'milliseconds': value}}}, identifier='owned-wait')
                        deadline = time.monotonic() + 3
                        while time.monotonic() < deadline and (not marker.exists() or 'R' not in marker.read_text()):
                            time.sleep(.005)
                        self.assertTrue(marker.exists() and 'R' in marker.read_text(), 'Actual CLI signal fixture did not start')
                        rows = process_table()
                        leaders = [pid for pid, row in rows.items() if row[0] == client.process.pid]
                        self.assertEqual(len(leaders), 1)
                        leader = leaders[0]
                        workers = [pid for pid, row in rows.items() if row[0] == leader]
                        self.assertEqual(len(workers), 1)
                        worker = workers[0]
                        self.assertEqual(rows[leader][1], leader)
                        self.assertEqual(rows[worker][1], leader)
                        descendants = [pid for pid, row in rows.items() if row[0] == worker]
                        self.assertEqual(len(descendants), 1, 'Owned descendant did not start')
                        self.assertEqual(rows[descendants[0]][1], leader)
                        observed = {leader, worker, descendants[0]}
                        client.send('notifications/cancelled', {'requestId': 'owned-wait'}, notification=True)
                        deadline = time.monotonic() + 2
                        stopped = False
                        while time.monotonic() < deadline:
                            row = process_table().get(client.process.pid)
                            if row and row[2].startswith('T'):
                                stopped = True
                                break
                            time.sleep(.005)
                        self.assertTrue(stopped, 'Owned host did not pause after forwarding its real group TERM')
                        deadline = time.monotonic() + 1
                        while time.monotonic() < deadline and 'T' not in marker.read_text():
                            time.sleep(.005)
                        self.assertIn('T', marker.read_text(), 'Actual CLI must receive TERM before host death')
                        at_term = process_table()
                        for pid in [worker, descendants[0]]:
                            self.assertIn(pid, at_term, 'Ignoring-TERM fixture ended before the host-death event')
                            self.assertFalse(at_term[pid][2].startswith('Z'), 'Fixture must survive TERM to test the lifetime monitor')
                        client.process.kill()  # Only our Popen child, never a PID discovered from ps.
                        client.process.wait(timeout=3)
                        deadline = time.monotonic() + 1
                        live = observed
                        while live and time.monotonic() < deadline:
                            rows = process_table()
                            live = {pid for pid in observed if pid in rows and not rows[pid][2].startswith('Z')}
                            if live:
                                time.sleep(.01)
                        self.assertFalse(live, 'Actual worker survived host death during TERM grace')
                    finally:
                        if client.process.poll() is None:
                            client.process.kill()
                            client.process.wait(timeout=3)
                        client.close()
                        # A RED baseline may orphan the harmless wait5000. Let
                        # it finish naturally; observation grants no kill authority.
                        deadline = time.monotonic() + 7
                        while observed and time.monotonic() < deadline:
                            rows = process_table()
                            observed = {pid for pid in observed if pid in rows and not rows[pid][2].startswith('Z')}
                            if observed:
                                time.sleep(.05)
                        self.assertFalse(observed, 'Bounded owned fixture did not finish')


if __name__ == '__main__':
    unittest.main()
