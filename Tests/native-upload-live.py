#!/usr/bin/env python3
"""Explicit opt-in native-upload acceptance using only owned Safari fixtures.

Examples:
  python3 Tests/native-upload-live.py --live-gui --binary .build/debug/safari-browser
  python3 Tests/native-upload-live.py --live-gui --binary .build/debug/safari-browser --case cancel --case timeout

Cancel races delivery intentionally: losing that race is a failure, not evidence
of cancellation. A timeout that never shows the chooser is skipped. No view
preferences are changed. Reports contain only owned metadata and fixed reasons.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import uuid


def acceptance(case, command, page, expected, *, observed_panel, observer, clipboard_equal, cleanup):
    def result(status, reason):
        return {'status': status, 'reason': reason}
    if cleanup != 'closed':
        return result('fail', 'owned_cleanup_incomplete')
    if clipboard_equal is not True:
        return result('fail', 'clipboard_restore_not_verified')
    if command.get('status') == 'timeout' or command.get('reason') == 'cleanup_failed' or command.get('cleanupFailed'):
        return result('fail', 'outer_watchdog_or_process_cleanup_failed')
    if command.get('stderrTruncated') or command.get('diagnosticsComplete') is not True:
        return result('fail', 'diagnostics_incomplete')
    if case == 'success':
        matches = isinstance(page, dict) and page.get('count') == 1 and page.get('trusted') is True
        matches = matches and page.get('name') == expected['name'] and page.get('size') == expected['size']
        matches = matches and page.get('hash') == expected['sha256']
        if command.get('status') != 'ok' or command.get('exitCode') != 0 or not matches:
            return result('fail', 'command_or_delivery_mismatch')
        return result('pass', 'trusted_file_bytes_and_cleanup_verified')
    if command.get('status') != 'error' or type(command.get('exitCode')) is not int or command['exitCode'] <= 0:
        return result('fail', 'negative_case_did_not_fail_normally')
    if not isinstance(page, dict) or page.get('count') != 0 or page.get('trusted') is not False or page.get('hash') is not None:
        return result('fail', 'negative_case_received_file_or_unknown_receipt')
    if command.get('confirmationCount') != 0:
        return result('fail', 'negative_case_dispatched_confirmation')
    if observer not in ('observed', 'cancelled', 'not-observed'):
        return result('fail', 'panel_observation_incomplete')
    if not observed_panel:
        return result('skip', 'chooser_not_observed_no_gui_acceptance')
    if case == 'cancel' and observer != 'cancelled':
        return result('fail', 'cancel_outcome_unknown_no_retry')
    if case == 'timeout' and command.get('timeoutObserved') is not True:
        return result('fail', 'deadline_failure_not_observed')
    return result('pass', 'negative_case_and_cleanup_verified')


def identity(window_id, url, marker):
    if type(window_id) is not int or window_id <= 0:
        raise ValueError('invalid_owned_window')
    if re.fullmatch(r'sb-upload-[0-9a-f]{32}', marker) is None:
        raise ValueError('invalid_owned_marker')
    if re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}/' + marker, url) is None:
        raise ValueError('invalid_owned_url')
    return f'''tell application "Safari"
 if not (exists window id {window_id}) then error "owned window unavailable"
 if (count tabs of window id {window_id}) is not 1 then error "owned tabs changed"
 set ownedURL to URL of current tab of window id {window_id}
 if ownedURL is not "{url}" and ownedURL is not "{url}#received" then error "owned URL changed"
 if id of front window is not {window_id} then error "owned window is not front"
end tell
 tell application "System Events" to tell process "Safari"
 if not frontmost then error "owned focus changed"
 set ownedWindows to windows whose name contains "{marker}"
 if (count ownedWindows) is not 1 then error "owned AX window ambiguous"
 set ownedWindow to item 1 of ownedWindows
 if front window is not ownedWindow then error "owned AX window is not front"
end tell'''


PANEL_CHECK = '''tell application "System Events" to tell process "Safari"
 if (count sheets of ownedWindow) is not 1 then error "unique owned panel unavailable"
 set ownedPanel to sheet 1 of ownedWindow
 if (value of attribute "AXIdentifier" of ownedPanel) is not "open-panel" then error "unexpected panel"
 if (count sheets of ownedPanel) is not 0 then error "nested panel refused"
end tell'''

CANCEL_ONCE = '''tell application "System Events" to tell process "Safari"
 set candidates to buttons of splitter group 1 of ownedPanel whose name is "Cancel" or name is "取消"
 if (count candidates) is not 1 then error "unique Cancel unavailable"
 set cancelButton to item 1 of candidates
 if not (enabled of cancelButton) then error "Cancel unavailable"
 if (value of attribute "AXIdentifier" of cancelButton) is not "CancelButton" then error "Cancel identity changed"
 perform action "AXPress" of cancelButton
 repeat 30 times
  if (count sheets of ownedWindow) is 0 then exit repeat
  delay 0.1
 end repeat
 if (count sheets of ownedWindow) is not 0 then error "Cancel outcome unknown; no retry"
end tell'''


def observer_script(window_id, url, marker, cancel=False):
    owned = identity(window_id, url, marker)
    action = CANCEL_ONCE + '\nreturn "cancelled"' if cancel else 'return "observed"'
    return f'''considering case
with timeout of 30 seconds
 repeat 200 times
  {owned}
  tell application "System Events" to tell process "Safari" to set panelCount to count sheets of ownedWindow
  if panelCount is not 0 then
   {PANEL_CHECK}
   {owned}
   {action}
  end if
  delay 0.05
 end repeat
 return "not-observed"
end timeout
end considering'''


def cleanup_script(window_id, url, marker, cancel_reserved=False):
    owned = identity(window_id, url, marker)
    action = 'error "Cancel already reserved; no retry"' if cancel_reserved else PANEL_CHECK + '\n' + owned + '\n' + CANCEL_ONCE
    return f'''considering case
with timeout of 15 seconds
 {owned}
 tell application "System Events" to tell process "Safari" to set panelCount to count sheets of ownedWindow
 if panelCount is not 0 then
  {action}
 end if
 {owned}
 tell application "System Events" to tell process "Safari" to if (count sheets of ownedWindow) is not 0 then error "owned panel remains"
 tell application "Safari"
  repeat 30 times
   set pendingHash to do JavaScript "window.fixtureDelivery.count === 1 && window.fixtureDelivery.hash === null" in current tab of window id {window_id}
   if pendingHash is false then exit repeat
   delay 0.1
  end repeat
  set pageResult to do JavaScript "JSON.stringify(window.fixtureDelivery)" in current tab of window id {window_id}
 end tell
 {owned}
 tell application "Safari" to close window id {window_id}
 repeat 20 times
  tell application "System Events" to tell process "Safari" to set remainingAX to count (windows whose name contains "{marker}")
  tell application "Safari"
   set remainingWindow to exists window id {window_id}
   if remainingWindow then set remainingWindow to ((count tabs of window id {window_id}) is not 0 or visible of window id {window_id})
  end tell
  if not remainingWindow and remainingAX is 0 then return "closed" & linefeed & pageResult
  delay 0.1
 end repeat
 error "Close outcome unknown; no retry"
end timeout
end considering'''


def creation_script(url, marker):
    identity(1, url, marker)  # Validate interpolated literals before building source.
    return f'''considering case
with timeout of 12 seconds
 tell application "Safari"
  make new document with properties {{URL:"{url}"}}
  set ownIDs to {{}}
  repeat with candidate in windows
   if (count tabs of candidate) is 1 then
    if URL of current tab of candidate is "{url}" then set end of ownIDs to id of candidate
   end if
  end repeat
  if (count ownIDs) is not 1 then error "created identity unknown; no retry"
  set ownID to item 1 of ownIDs
  repeat 60 times
   if name of current tab of window id ownID is "{marker}" then exit repeat
   delay 0.1
  end repeat
  if (count tabs of window id ownID) is not 1 or URL of current tab of window id ownID is not "{url}" then error "created owner changed"
  if (do JavaScript "document.readyState === 'complete' && !!document.getElementById('fixture-file') && !!window.fixtureDelivery" in current tab of window id ownID) is not true then error "fixture not ready"
  set index of window id ownID to 1
  activate
  return ownID
 end tell
end timeout
end considering'''


FINGERPRINT_SWIFT = r'''import AppKit
import CryptoKit
import Foundation
func refuse() -> Never { exit(70) }
let board = NSPasteboard.general
let generation = board.changeCount
let items = board.pasteboardItems ?? []
guard items.count <= 1024 else { refuse() }
var digest = SHA256()
var total = 0
func feed(_ data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
    digest.update(data: data)
}
feed(Data(String(items.count).utf8))
for item in items {
    guard item.types.count <= 256 else { refuse() }
    feed(Data(String(item.types.count).utf8))
    for type in item.types {
        guard let data = item.data(forType: type), data.count <= 64 * 1024 * 1024 - total else { refuse() }
        total += data.count
        feed(Data(type.rawValue.utf8)); feed(data)
    }
}
guard board.changeCount == generation else { refuse() }
print(digest.finalize().map { String(format: "%02x", $0) }.joined())
'''


class Runner:
    """Use the existing unreaped-leader process-group watchdog for every child."""
    def __init__(self, directory):
        path = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark-performance.py'
        spec = importlib.util.spec_from_file_location('upload_owned_processes', path)
        self.bounded = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bounded)
        self.env = self.bounded.isolated_environment(str(directory), True)
        self.local = threading.local()
        original = self.bounded.parse_trace
        def parse(data, **kwargs):
            self.local.stderr = data
            return original(data, **kwargs)
        self.bounded.parse_trace = parse

    def run(self, argv, timeout):
        self.local.stderr = b''
        record, stdout = self.bounded.run_process(argv, self.env, timeout, capture_stdout=True)
        stderr = self.local.stderr.decode('utf-8', errors='replace')
        record['diagnosticsComplete'] = not record.get('stderrTruncated', True)
        record['confirmationCount'] = stderr.count('confirming file dialog: pressing named button')
        record['timeoutObserved'] = ('Native upload deadline expired;' in stderr
                                     or re.search(r'Process timed out after [0-9.]+ seconds: native file URL upload', stderr) is not None)
        return record, stdout

    def native(self, source, timeout=20):
        record, output = self.run(['/usr/bin/osascript', '-e', source], timeout)
        if record['status'] != 'ok' or record['exitCode'] != 0:
            raise RuntimeError('owned_native_operation_incomplete')
        return output.decode('utf-8').strip()


def fixture_html(marker, event, mutation):
    if event not in ('input', 'change') or mutation not in ('keep', 'clear', 'replace', 'url'):
        raise ValueError('invalid_fixture_mode')
    mutate = {'keep': '', 'clear': "input.value='';", 'replace': 'input.replaceWith(input.cloneNode());',
              'url': "history.pushState(null,'','#received');"}[mutation]
    return f'''<!doctype html><meta charset="utf-8"><title>{marker}</title><h1>{marker}</h1><input type=file id=fixture-file>
<script>
window.fixtureDelivery={{count:0,trusted:false,hash:null}};
const input=document.getElementById('fixture-file');
input.addEventListener('{event}', event=>{{
 const files=Array.from(input.files);
 window.fixtureDelivery={{count:files.length,trusted:event.isTrusted,hash:null}};
 if(files.length===1){{
  Object.assign(window.fixtureDelivery,{{name:files[0].name,size:files[0].size}});
  const receipt=window.fixtureDelivery;
  files[0].arrayBuffer().then(b=>crypto.subtle.digest('SHA-256',b)).then(b=>receipt.hash=Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join('')).catch(()=>receipt.hash='failed');
 }}
 {mutate}
}});
</script>'''.encode('utf-8')


class Harness:
    def __init__(self, runner, binary, directory, fingerprint, options):
        self.runner, self.binary, self.directory = runner, binary, directory
        self.fingerprint, self.options = fingerprint, options
        self.window_id = None
        self.cancel_reserved = False
        self.close_reserved = False
        self.observer_thread = None
        self.observer_result = 'not-started'
        self.marker = 'sb-upload-' + uuid.uuid4().hex
        self.url = None

    def clipboard(self):
        record, output = self.runner.run([str(self.fingerprint)], 5)
        digest = output.decode('ascii', errors='replace').strip()
        if record['status'] != 'ok' or re.fullmatch('[0-9a-f]{64}', digest) is None:
            raise RuntimeError('clipboard_fingerprint_unavailable')
        return digest

    def observe(self, case):
        if case == 'cancel':
            self.cancel_reserved = True  # Reserve before dispatch; uncertainty never permits a retry.
        def operation():
            try:
                self.observer_result = self.runner.native(observer_script(self.window_id, self.url, self.marker, case == 'cancel'), 35)
            except Exception:
                self.observer_result = 'unknown'
        self.observer_thread = threading.Thread(target=operation, daemon=True)
        self.observer_thread.start()

    def cleanup(self):
        if self.close_reserved:
            return 'retained', None
        if self.observer_thread is not None and self.observer_thread.is_alive():
            return 'retained', None
        if self.window_id is None:
            return 'unknown-created-window', None
        self.close_reserved = True
        try:
            answer = self.runner.native(cleanup_script(self.window_id, self.url, self.marker, self.cancel_reserved), 20)
            status, raw = answer.split('\n', 1)
            if status != 'closed':
                return 'retained', None
            return 'closed', json.loads(raw)
        except Exception:
            return 'retained', None

    def exercise(self, case):
        folder = self.directory / ('.隱藏 資料夾\'' + self.marker)
        folder.mkdir(mode=0o700)
        target = folder / ('.' + self.marker + "-中文 空白'檔案.txt")
        data = (self.marker.encode() + b'\n')
        data = (data + b'x' * max(0, self.options.size_bytes - len(data)))[:self.options.size_bytes]
        target.write_bytes(data)
        expected = {'name': target.name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        body = fixture_html(self.marker, self.options.page_event, self.options.after_selection)
        route = '/' + self.marker
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != route:
                    self.send_error(404); return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{server.server_port}{route}'
        command = {'status': 'error', 'exitCode': None}
        clipboard_equal = False
        cleanup, page = 'not-created', None
        failure = None
        try:
            before = self.clipboard()
            (self.directory / 'owned-identity.json').write_text(json.dumps({'windowID': None, 'url': self.url, 'marker': self.marker, 'creationAttempted': True}))
            created = self.runner.native(creation_script(self.url, self.marker), 17)
            if not created.isdecimal() or int(created) <= 0:
                raise RuntimeError('created_identity_unknown')
            self.window_id = int(created)
            # Persist only owned identity so uncertain cleanup can be inspected manually.
            (self.directory / 'owned-identity.json').write_text(json.dumps({'windowID': self.window_id, 'url': self.url, 'marker': self.marker}))
            if case in ('cancel', 'timeout'):
                self.observe(case)
            seconds = self.options.timeout_seconds if case == 'timeout' else 25
            command, _ = self.runner.run([str(self.binary), 'upload', '--native', '--timeout', str(seconds),
                                          '--url-exact', self.url, '#fixture-file', str(target)], 45)
            clipboard_equal = before == self.clipboard()
        except Exception:
            failure = 'fixture_operation_incomplete'
        finally:
            if self.observer_thread:
                self.observer_thread.join(36)
            cleanup, page = self.cleanup()
            server.shutdown(); server.server_close()
        report = acceptance(case, command, page, expected, observed_panel=self.observer_result in ('observed', 'cancelled'),
                            observer=self.observer_result, clipboard_equal=clipboard_equal, cleanup=cleanup)
        if failure:
            report = {'status': 'fail', 'reason': failure}
        report.update(case=case, command=command, observer=self.observer_result, cleanup=cleanup,
                      clipboardEqual=clipboard_equal, expected=expected,
                      receipt={'observed': isinstance(page, dict),
                               'singleFile': isinstance(page, dict) and page.get('count') == 1,
                               'empty': isinstance(page, dict) and page.get('count') == 0,
                               'trusted': isinstance(page, dict) and page.get('trusted') is True,
                               'nameMatches': isinstance(page, dict) and page.get('name') == expected['name'],
                               'sizeMatches': isinstance(page, dict) and page.get('size') == expected['size'],
                               'sha256Matches': isinstance(page, dict) and page.get('hash') == expected['sha256']})
        return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-gui', action='store_true', help='Allow owned Safari windows and native upload clipboard use')
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--case', choices=['success', 'cancel', 'timeout'], action='append')
    parser.add_argument('--size-bytes', type=int, default=1024)
    parser.add_argument('--page-event', choices=['input', 'change'], default='change')
    parser.add_argument('--after-selection', choices=['keep', 'clear', 'replace', 'url'], default='keep')
    parser.add_argument('--timeout-seconds', type=float, default=3)
    options = parser.parse_args(argv)
    if not options.live_gui:
        print(json.dumps({'status': 'skip', 'reason': 'live_gui_not_requested'})); return 77
    if sys.platform != 'darwin':
        print(json.dumps({'status': 'skip', 'reason': 'macos_required'})); return 77
    if options.binary is None or not options.binary.is_file():
        parser.error('--binary must identify an existing test executable')
    if not 1 <= options.size_bytes <= 32 * 1024 * 1024 or not .001 <= options.timeout_seconds <= 10:
        parser.error('fixture size must be 1..32 MiB and timeout .001..10 seconds')
    directory = Path(tempfile.mkdtemp(prefix='sb-native-upload-'))
    os.chmod(directory, 0o700)
    report = {'schemaVersion': 1, 'cases': [], 'artifacts': str(directory)}
    try:
        runner = Runner(directory)
        record, output = runner.run([str(options.binary.resolve()), 'dialog', 'list'], 8)
        if record['status'] != 'ok' or output.strip() != b'no blocking dialog found':
            report.update(status='skip', reason='gui_preflight_not_clear')
            return 77
        source = directory / 'fingerprint.swift'
        source.write_text(FINGERPRINT_SWIFT)
        fingerprint = directory / 'fingerprint'
        sdk_record, sdk_output = runner.run(['/usr/bin/xcrun', '--show-sdk-path'], 5)
        sdk = sdk_output.decode('utf-8').strip()
        if sdk_record['status'] != 'ok' or not Path(sdk).is_absolute() or not Path(sdk).is_dir():
            report.update(status='fail', reason='sdk_unavailable'); return 1
        compilation, _ = runner.run(['/usr/bin/xcrun', 'swiftc', '-sdk', sdk, str(source), '-o', str(fingerprint)], 45)
        if compilation['status'] != 'ok':
            report.update(status='fail', reason='fingerprint_build_failed'); return 1
        for index, case in enumerate(options.case or ['success']):
            fresh, fresh_output = runner.run([str(options.binary.resolve()), 'dialog', 'list'], 8)
            if fresh['status'] != 'ok' or fresh_output.strip() != b'no blocking dialog found':
                report['cases'].append({'case': case, 'status': 'skip', 'reason': 'gui_preflight_not_clear'})
                break
            case_dir = directory / str(index)
            case_dir.mkdir(mode=0o700)
            outcome = Harness(runner, options.binary.resolve(), case_dir, fingerprint, options).exercise(case)
            report['cases'].append(outcome)
            # Never run another GUI case after uncertain ownership/cleanup.
            if outcome['status'] == 'fail':
                break
        statuses = [item['status'] for item in report['cases']]
        report['status'] = 'fail' if 'fail' in statuses else 'skip' if 'skip' in statuses else 'pass'
        return {'pass': 0, 'skip': 77, 'fail': 1}[report['status']]
    except Exception:
        report.update(status='fail', reason='harness_incomplete')
        return 1
    finally:
        (directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    raise SystemExit(main())
