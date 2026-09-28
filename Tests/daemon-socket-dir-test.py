#!/usr/bin/env python3
"""Reject owned non-directory daemon paths without starting a service or Safari."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = str(Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve())


class DaemonSocketDirectoryTests(unittest.TestCase):
    def invoke(self, action, path, explicit, unsafe):
        env = {key: value for key, value in os.environ.items() if not key.startswith('SAFARI_BROWSER_')}
        env['TMPDIR'] = str(path if not explicit else path.parent)
        args = [BIN, 'daemon', action, '--name', 'owned-type']
        if explicit:
            args += ['--socket-dir', str(path)]
        if unsafe:
            args += ['--allow-unsafe-socket-dir']
        return subprocess.run(args, env=env, capture_output=True, timeout=3)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 64, result.stderr.decode())
        self.assertIn(b'not a directory', result.stderr)
        self.assertNotIn(b'not statable', result.stderr)
        self.assertNotIn(b'world-writable', result.stderr)
        self.assertEqual(result.stdout, b'')

    def test_management_commands_reject_non_directories(self):
        with tempfile.TemporaryDirectory(prefix='sb-dir-', dir='/tmp') as directory:
            root = Path(directory)
            file = root / 'owned-file'
            file.write_text('owned')
            link = root / 'owned-link'
            link.symlink_to(file)
            fifo = root / 'owned-fifo'
            os.mkfifo(fifo, 0o600)
            for action in ['start', 'stop', 'status', 'logs', '__serve']:
                for path in [file, link, fifo]:
                    for explicit in [False, True]:
                        for unsafe in [False, True]:
                            with self.subTest(action=action, path=path.name, explicit=explicit, unsafe=unsafe):
                                self.assert_rejected(self.invoke(action, path, explicit, unsafe))
            self.assertEqual(file.read_text(), 'owned')
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['owned-fifo', 'owned-file', 'owned-link'])

    def test_logs_cannot_override_the_file_type(self):
        # This safe caller is also the mutation oracle: even a deliberately
        # broken resolver cannot start a service through the logs command.
        with tempfile.TemporaryDirectory(prefix='sb-dir-', dir='/tmp') as directory:
            path = Path(directory, 'owned-file')
            path.write_text('owned')
            self.assert_rejected(self.invoke('logs', path, True, True))


if __name__ == '__main__':
    unittest.main()
