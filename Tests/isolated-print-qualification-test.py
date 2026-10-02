import copy
import runpy
import unittest
from pathlib import Path

module = runpy.run_path(str(Path(__file__).with_name('isolated-print-qualification.py')))

class QualificationTests(unittest.TestCase):
    def context(self):
        return dict(github_actions=True, runner_environment='github-hosted', runner_os='macOS',
                    arch='arm64', model='VirtualMac2,1', vmm_present='1', os_version='27.0',
                    os_build='26A428', safari_version='27.0', safari_build='22625.1.29.11.27',
                    printers_none=True, default_printer_none=True)

    def test_cloud_vm_with_exact_build_and_no_printers_passes_base(self):
        self.assertEqual(module['base_failures'](self.context()), [])

    def test_wrong_provenance_platform_build_or_printer_state_refuses(self):
        for key, value in [('github_actions', False), ('runner_environment', 'self-hosted'),
                           ('runner_os', 'Linux'), ('arch', 'x86_64'), ('os_build', '25G83'),
                           ('safari_build', 'old'), ('printers_none', False),
                           ('default_printer_none', None)]:
            with self.subTest(key=key):
                context = self.context(); context[key] = value
                self.assertTrue(module['base_failures'](context))
        context = self.context(); context.update(model='Mac17,6', vmm_present='0')
        self.assertTrue(module['base_failures'](context))

    def test_missing_information_is_not_success(self):
        for key in self.context():
            if key in ('model', 'vmm_present'): continue  # Either affirmative VM signal is enough.
            context = self.context(); del context[key]
            self.assertTrue(module['base_failures'](context), key)
        self.assertTrue(module['base_failures']({}))

    def test_printer_absence_requires_recognized_success_or_absence(self):
        classify = module['printer_absence']
        self.assertTrue(classify('destinations', 0, '', ''))
        self.assertTrue(classify('destinations', 1, '', 'lpstat: No destinations added.\n'))
        self.assertTrue(classify('default', 0, 'no system default destination\n', ''))
        for code, out, err in [(1, '', ''), (1, '', 'scheduler unavailable'),
                               (0, 'device for printer: ipp://example.test/print', ''),
                               (-9, '', ''), (0, '', 'unexpected warning')]:
            self.assertFalse(classify('destinations', code, out, err))
        self.assertFalse(classify('default', 0, '', ''))

if __name__ == '__main__': unittest.main()
