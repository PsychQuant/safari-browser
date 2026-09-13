#!/usr/bin/env python3
"""#122: the source entry uses shared policy and never maps build errors to 1."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ENTRY = Path(__file__).resolve().parents[1] / 'scripts/verify-install-signature.swift'

class SignatureEntrypointTests(unittest.TestCase):
    def test_direct_entry_forwards_spaced_option_and_verdict(self):
        result = subprocess.run([str(ENTRY),'--require-shape','Apple system','/bin/ls'],text=True,capture_output=True,timeout=90)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('durable: Apple system',result.stdout)
        self.assertIn('signing identity and designated requirement stay the same',result.stdout)

    def test_missing_helper_is_environment_error(self):
        with tempfile.TemporaryDirectory(prefix='guard source ') as directory:
            entry=Path(directory)/'guard source.swift'
            shutil.copy2(ENTRY,entry)
            result=subprocess.run([str(entry),'/bin/ls'],text=True,capture_output=True,timeout=5)
            self.assertEqual(result.returncode,70,result.stderr)
            self.assertIn('helper unavailable',result.stderr)

    def test_build_failure_is_environment_error(self):
        with tempfile.TemporaryDirectory() as directory:
            compiler=Path(directory)/'swiftc'
            compiler.write_text('#!/bin/sh\nexit 42\n')
            compiler.chmod(0o755)
            result=subprocess.run([str(ENTRY),'/bin/ls'],env=dict(os.environ,PATH=directory+os.pathsep+os.environ['PATH']),text=True,capture_output=True,timeout=15)
            self.assertEqual(result.returncode,70,result.stderr)
            self.assertIn('not a signature verdict',result.stderr)
            self.assertNotIn('ad-hoc signature:',result.stderr)

if __name__=='__main__':unittest.main()
