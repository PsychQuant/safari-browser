#!/usr/bin/env python3
"""Qualify a fresh hosted macOS VM. This module contains no Print action."""
import argparse
import json
import os
import plistlib
import re
import subprocess
import tempfile
import uuid
from pathlib import Path

EXPECTED_OS_BUILD = '26A428'
EXPECTED_SAFARI_BUILD = '22625.1.29.11.27'


def platform_failures(context):
    checks = {
        'github_actions': context.get('github_actions') is True,
        'github_hosted': context.get('runner_environment') == 'github-hosted',
        'macos': context.get('runner_os') == 'macOS',
        'arm64': context.get('arch') == 'arm64',
        'virtual_machine': str(context.get('model', '')).startswith('VirtualMac') or context.get('vmm_present') == '1',
        'os_version': context.get('os_version') in ('27.0', '27.0.0'),
        'os_build': context.get('os_build') == EXPECTED_OS_BUILD,
        'safari_version': context.get('safari_version') == '27.0',
        'safari_build': context.get('safari_build') == EXPECTED_SAFARI_BUILD,
    }
    return [name for name, passed in checks.items() if not passed]


def base_failures(context):
    reasons = platform_failures(context)
    if context.get('printers_none') is not True: reasons.append('printers_not_proven_absent')
    if context.get('default_printer_none') is not True: reasons.append('default_printer_not_proven_absent')
    return reasons


def printer_absence(kind, code, stdout, stderr):
    out, err = stdout.strip(), stderr.strip()
    if kind == 'destinations':
        return (code == 0 and not out and not err) or (code == 1 and not out and err == 'lpstat: No destinations added.')
    return code in (0, 1) and out == 'no system default destination' and not err


def call(args, timeout=5):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout,
                                env={**os.environ, 'LC_ALL': 'C'})
        return dict(code=result.returncode, stdout=result.stdout, stderr=result.stderr, timed_out=False)
    except subprocess.TimeoutExpired:
        return dict(code=None, stdout='', stderr='command timed out', timed_out=True)
    except OSError as error:
        return dict(code=None, stdout='', stderr=type(error).__name__, timed_out=False)


def value(args):
    result = call(args)
    return result['stdout'].strip() if result['code'] == 0 else None


def baseline():
    context = dict(github_actions=os.environ.get('GITHUB_ACTIONS') == 'true',
                   runner_environment=os.environ.get('RUNNER_ENVIRONMENT'),
                   runner_os=os.environ.get('RUNNER_OS'), arch=value(['/usr/bin/uname', '-m']),
                   model=value(['/usr/sbin/sysctl', '-n', 'hw.model']),
                   vmm_present=value(['/usr/sbin/sysctl', '-n', 'kern.hv_vmm_present']),
                   os_version=value(['/usr/bin/sw_vers', '-productVersion']),
                   os_build=value(['/usr/bin/sw_vers', '-buildVersion']),
                   printers_none=None, default_printer_none=None)
    try:
        with open('/Applications/Safari.app/Contents/Info.plist', 'rb') as file:
            info = plistlib.load(file)
        context.update(safari_version=info.get('CFBundleShortVersionString'), safari_build=info.get('CFBundleVersion'))
    except (OSError, plistlib.InvalidFileException):
        context.update(safari_version=None, safari_build=None)
    # A local invocation cannot reach CUPS or Safari automation.
    if platform_failures(context): return context
    if any(os.environ.get(key) for key in ('CUPS_SERVER', 'IPP_PORT', 'LPDEST', 'PRINTER')):
        context['printing_environment_overrides'] = True
        return context
    for kind, arguments, field in [('destinations', ['-v'], 'printers_none'), ('default', ['-d'], 'default_printer_none')]:
        result = call(['/usr/bin/lpstat', *arguments])
        context[field] = printer_absence(kind, result['code'], result['stdout'], result['stderr'])
        # Do not publish printer URIs or arbitrary diagnostic text.
        context[kind + '_query'] = dict(code=result['code'], timed_out=result['timed_out'], absence_recognized=context[field])
    return context


def safari_fixture():
    nonce = 'IDD102-' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='idd102-qualification-') as directory:
        page = Path(directory) / 'fixture.html'
        page.write_text(f'<!doctype html><title>{nonce}</title><h1>{nonce}</h1>')
        url = page.as_uri().replace('\\', '\\\\').replace('"', '\\"')
        script = f'''set fixtureURL to "{url}"
set fixtureName to "{nonce}"
set ownID to 0
with timeout of 15 seconds
 tell application "Safari"
  make new document with properties {{URL:fixtureURL}}
  set ownedIDs to {{}}
  repeat with w in windows
   if (count tabs of w) is 1 then
    if URL of current tab of w is fixtureURL then set end of ownedIDs to id of w
   end if
  end repeat
  if (count ownedIDs) is not 1 then error "unique owned fixture unavailable"
  set ownID to item 1 of ownedIDs
  set index of window id ownID to 1
  activate
  repeat 50 times
   if name of current tab of window id ownID is fixtureName then exit repeat
   delay 0.1
  end repeat
  if name of current tab of window id ownID is not fixtureName then error "fixture did not load"
  if URL of current tab of window id ownID is not fixtureURL then error "fixture URL changed"
  if not (visible of window id ownID) then error "fixture is not visible"
  close window id ownID
  repeat 50 times
   if not (exists window id ownID) then return "owned fixture loaded and closed"
   if (count tabs of window id ownID) is 0 and not (visible of window id ownID) then return "owned fixture loaded and closed"
   delay 0.1
  end repeat
  error "owned cleanup not observed; no retry"
 end tell
end timeout'''
        result = call(['/usr/bin/osascript', '-e', script], timeout=20)
        return dict(code=result['code'], timed_out=result['timed_out'],
                    owned_fixture_loaded_and_closed=result['code'] == 0 and result['stdout'].strip() == 'owned fixture loaded and closed',
                    diagnostic=re.sub(r'/Users/[^\s\"\']+', '<user-path>', result['stderr'])[:2048])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    context = baseline()
    reasons = base_failures(context)
    automation = None
    if not reasons:
        automation = safari_fixture()
        if not automation['owned_fixture_loaded_and_closed']: reasons.append('safari_automation_or_cleanup_unverified')
    report = dict(schema=1, print_attempted=False, qualified_for_next_stage=not reasons,
                  context=context, reasons=reasons, automation=automation,
                  run_id=os.environ.get('GITHUB_RUN_ID'))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=True))
    print(json.dumps(report, ensure_ascii=True))
    return 0 if not reasons else 77


if __name__ == '__main__': raise SystemExit(main())
