#!/usr/bin/env python3
"""#108: query an owned confirm while its click is still awaiting JavaScript.

Exit 77 is not acceptance. No fixture is created before the session check.
A retained fixture keeps its identity and dismissal-attempt marker in artifacts.
"""
import argparse
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('background_fixture', ROOT / 'Tests/e2e-background-dialog.py')
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
require, run, quoted = common.require, common.run, common.quoted


def owned_messages(nonce, url=None):
    allowed = (nonce, 'JavaScript ' + nonce)
    if url is not None:
        parsed = urlsplit(url)
        require(parsed.scheme == 'http' and parsed.hostname == '127.0.0.1'
                and parsed.port is not None and parsed.path == '/' + nonce
                and not parsed.query and not parsed.fragment and not parsed.username,
                'unexpected fixture origin')
        # Measured on Safari 27 Traditional Chinese. Exact origin plus nonce,
        # never prefix/substring matching against arbitrary dialog text.
        allowed += (f'來自「http://127.0.0.1:{parsed.port}」： {nonce}',)
    return allowed


def expected_cancel(status, listing, window_id, nonce, url=None):
    """Require exact raw text and known ID; never select the default button."""
    require(type(window_id) is int and window_id > 0, 'missing owned window ID')
    require(status.get('state') == 'present' and type(status.get('window_id')) is int
            and status['window_id'] == window_id, 'query does not describe the owned dialog')
    messages = status.get('messages')
    require(isinstance(messages, list) and len(messages) == 1
            and messages[0] in owned_messages(nonce, url), 'unexpected raw dialog text')
    lines = listing.splitlines()
    require(bool(lines) and lines[0] == 'blocking dialog present', 'global dialog ownership incomplete')
    message_rows = [line[11:] for line in lines if line.startswith('  message: ')]
    button_rows = [line[11:] for line in lines if line.startswith('  buttons: ')]
    require(len(message_rows) == len(button_rows) == 1, 'ambiguous dialog listing')
    require(json.loads(message_rows[0]) == messages[0], 'listing message differs from raw observation')
    buttons = json.loads('[' + button_rows[0] + ']')
    candidates = [b for b in buttons if b in ('Cancel', '取消')]
    require(len(candidates) == 1, 'unique named Cancel unavailable')
    return messages[0], candidates[0]


def verify_query(outcome, elapsed, state, window_id=None):
    require(outcome.returncode == 0, 'query failed: ' + outcome.stderr)
    require(elapsed < 3, f'query exceeded 3 seconds ({elapsed:.3f}s)')
    data = json.loads(outcome.stdout)
    require(data.get('reason') is None, 'query result is incomplete')
    require(data.get('state') == state, 'unexpected native dialog state: ' + data.get('state', '<missing>'))
    require(type(data.get('window_id')) is int and data['window_id'] == window_id,
            'query window identity differs from fixture')
    return data


class Harness(common.Harness):
    def __init__(self, binary, checker, image_id, artifacts):
        super().__init__(binary, checker, image_id)
        self.nonce = 'current-dialog-' + uuid.uuid4().hex
        self.dialog_text = self.nonce
        self.artifacts = artifacts
        self.process = None
        self.armed = False
        self.server = None
        self.url = None
        self.env['SAFARI_BROWSER_NAME'] = 'fixture-' + self.nonce

    def persist(self):
        (self.artifacts / 'identity.json').write_text(json.dumps({
            'window_id': self.window_id, 'url': self.url, 'nonce': self.nonce,
            'dismiss_attempted': self.dismiss_attempted, 'armed': self.armed}, indent=2))

    def window_script(self, action='return "owned"'):
        require(type(self.window_id) is int and self.window_id > 0, 'owned window ID unavailable')
        return f'''tell application "Safari"
            if not (exists window id {self.window_id}) then return "gone"
            set w to window id {self.window_id}
            if (count tabs of w) is not 1 then return "retained"
            if (URL of current tab of w) is not {quoted(self.url)} then return "retained"
            {action}
        end tell'''

    def query(self):
        start = time.monotonic()
        result = self.cli('is', 'dialog', '--json', timeout=4)
        return result, time.monotonic() - start

    def start_page(self):
        body = (f'<!doctype html><meta charset="utf-8"><title>{self.nonce}</title>'
                '<button id="trigger">Test confirm</button><script>window.clickCount=0;'
                'document.getElementById("trigger").onclick=function(){window.clickCount++;'
                f'window.answer=confirm({json.dumps(self.nonce)});' + '};</script>').encode()
        path = '/' + self.nonce
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != path:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_):
                pass
        self.server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_port}{path}'
        self.creation_attempted = True
        self.persist()
        self.window_id = int(self.native(f'''tell application "Safari"
            make new document with properties {{URL:{quoted(self.url)}}}
            return id of front window
        end tell'''))
        self.persist()
        require(self.native(self.window_script('set index of w to 1\nactivate\nreturn "owned"')) == 'owned',
                'owned window changed before activation')
        ready = self.target('wait', '--js', "document.getElementById('trigger') !== null", timeout=12)
        require(ready.returncode == 0, 'fixture was not ready: ' + ready.stderr)

    def put_safari_in_background(self):
        self.require_owned()
        # Fixture setup only: Finder activation changes no documents or tabs.
        # The query must not activate Safari to manufacture a clear result.
        self.native('tell application "Finder" to activate')
        for _ in range(20):
            if self.native('tell application "System Events" to return frontmost of process "Safari"') == 'false':
                return
            time.sleep(0.1)
        raise common.VerificationError('could not establish inactive Safari fixture')

    def require_safari_background(self):
        require(self.native('tell application "System Events" to return frontmost of process "Safari"') == 'false',
                'query activated Safari or foreground changed')

    def dismiss_owned(self):
        require(not self.dismiss_attempted, 'an earlier dismissal is unresolved; no retry')
        self.require_owned()
        query, _ = self.query()
        require(query.returncode == 0, 'cannot inspect owned pending dialog')
        listing = self.cli('dialog', 'list')
        require(listing.returncode == 0, 'dialog list is incomplete')
        message, button = expected_cancel(json.loads(query.stdout), listing.stdout, self.window_id, self.nonce, self.url)
        self.require_owned()
        fd = os.open(self.artifacts / 'dismiss-attempt', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        self.dismiss_attempted = True
        self.persist()
        result = self.cli('dialog', 'dismiss', '--button', button,
                          '--expect-window-id', str(self.window_id), '--expect-message', message)
        require(result.returncode == 0, 'dismissal outcome unknown: ' + result.stderr)
        recovered = self.target('js', 'JSON.stringify({count:window.clickCount,answer:window.answer})')
        require(recovered.returncode == 0, 'owned JavaScript did not recover')
        require(json.loads(recovered.stdout) == {'count': 1, 'answer': False}, 'click replayed or wrong confirmation')
        self.armed = False
        self.persist()

    def exercise(self):
        initial = self.cli('dialog', 'list')
        require(initial.returncode == 0 and initial.stdout.strip() == 'no blocking dialog found',
                'existing or unknown dialog; fixture not created')
        require(self.check_session(), 'GUI became unavailable')
        self.start_page()
        self.put_safari_in_background()
        outcome, elapsed = self.query()
        verify_query(outcome, elapsed, 'clear', self.window_id)
        self.require_safari_background()
        print(f'Owned window {self.window_id}; inactive clear query {elapsed:.3f}s', flush=True)
        self.armed = True
        self.persist()
        self.process = subprocess.Popen([str(self.binary), '__mcp-exec', 'click', '#trigger', '--url-exact', self.url],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                        env=self.env, start_new_session=True)
        # Read-only polling allows the click to enter its handler. It never
        # retries the click and cannot dismiss or activate anything.
        deadline = time.monotonic() + 8
        observed = None
        while time.monotonic() < deadline:
            require(self.process.poll() is None, 'click exited before pending state was observed')
            outcome, elapsed = self.query()
            if outcome.returncode == 0 and json.loads(outcome.stdout).get('state') == 'present':
                observed = verify_query(outcome, elapsed, 'present', self.window_id)
                break
            time.sleep(0.1)
        require(observed is not None, 'owned confirm was not observed during click')
        require(self.process.poll() is None, 'click is no longer waiting; cannot prove independence')
        require(observed.get('messages') in ([message] for message in owned_messages(self.nonce, self.url)), 'wrong native dialog observed')
        print(f'Pending query returned in {elapsed:.3f}s while click remained running', flush=True)
        self.put_safari_in_background()
        outcome, elapsed = self.query()
        verify_query(outcome, elapsed, 'present', self.window_id)
        self.require_safari_background()
        require(self.process.poll() is None, 'click finished before inactive pending query')
        print(f'Inactive pending query {elapsed:.3f}s; Safari was not activated', flush=True)
        self.dismiss_owned()
        stdout, stderr = self.process.communicate(timeout=8)
        (self.artifacts / 'click.json').write_text(json.dumps({'code': self.process.returncode, 'stdout': stdout, 'stderr': stderr}))
        require(self.process.returncode == 0, 'click failed after owned cancellation: ' + stderr)
        outcome, elapsed = self.query()
        verify_query(outcome, elapsed, 'clear', self.window_id)
        print(f'Recovered clear query {elapsed:.3f}s; handler executed once', flush=True)
        return 0

    def cleanup(self):
        clean = False
        try:
            clean = super().cleanup()
        finally:
            try:
                if self.process is not None:
                    if self.process.poll() is None:
                        try:
                            os.killpg(self.process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    self.process.communicate(timeout=5)
            except (OSError, subprocess.SubprocessError) as error:
                clean = False
                print(f'Owned click cleanup incomplete: {error}', file=sys.stderr)
            if self.server is not None:
                self.server.shutdown()
            self.persist()
            (self.artifacts / 'cleanup.json').write_text(json.dumps({'complete': clean}))
        return clean


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight-only', action='store_true')
    args = parser.parse_args(argv)
    artifacts = Path(tempfile.mkdtemp(prefix='sb-current-dialog-'))
    checker = artifacts / 'session-check'
    gui = None
    status = 1
    try:
        if common.session_preflight(checker) == 77:
            print('SKIP: GUI unavailable; no fixture created, acceptance not performed.')
            return 77
        if args.preflight_only:
            print('Session preflight only; no GUI acceptance performed.')
            return 0
        binary = Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve()
        gui = Harness(binary, checker, common.image_identifier(binary), artifacts)
        gui.verify_process_group()
        status = gui.exercise()
    except (common.VerificationError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print('FAIL:', error, file=sys.stderr)
    finally:
        if gui is not None and not gui.cleanup():
            status = 1
            print(f'RETAINED owned fixture; inspect {artifacts}/identity.json; no acceptance PASS.', file=sys.stderr)
    if status == 0:
        print('PASS: current clear/pending/recovery, in-flight query, exactly one click and owned cleanup.')
    print('Artifacts:', artifacts)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
