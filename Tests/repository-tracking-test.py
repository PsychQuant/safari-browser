#!/usr/bin/env python3
"""Exercise the Git metadata paths used by a fresh CI checkout."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
CACHE = 'safari-vision/.xcodebuild'


def git(*arguments):
    return subprocess.run(['git', '-C', str(ROOT), *arguments], capture_output=True, text=True)


class RepositoryTrackingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        top = git('rev-parse', '--show-toplevel')
        if top.returncode or Path(top.stdout.strip()).resolve() != ROOT:
            if os.environ.get('GITHUB_ACTIONS') == 'true':
                raise AssertionError('CI checkout lacks this repository Git metadata')
            raise unittest.SkipTest('Source archive: Git tracking checks were not performed')

    def test_generated_xcode_tree_is_not_tracked(self):
        result = git('ls-files', '--', CACHE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '', 'Generated Xcode artifacts are tracked')

    def test_future_build_artifacts_and_dependency_checkouts_are_ignored(self):
        paths = [CACHE + '/Build/Products/fixture.o',
                 CACHE + '/SourcePackages/checkouts/fixture-dependency',
                 CACHE + '/Logs/Build/fixture.log']
        result = git('check-ignore', '--no-index', '--', *paths)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), set(paths))

    def test_checkout_submodule_auth_scan_succeeds(self):
        # This is the read-only portion of checkout's authentication cleanup;
        # malformed gitlinks fail before it can visit any submodule.
        result = git('submodule', 'foreach', '--recursive',
                     'git config --local --name-only --get-regexp core.sshCommand || :')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
