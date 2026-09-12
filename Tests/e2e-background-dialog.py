#!/usr/bin/env python3
"""#131: exercise a real pending background alert without touching user tabs.

The first preflight checks GUI lock state; exit 77 means NOT ACCEPTED, never
PASS. --preflight-only checks the session without contacting Safari. Run pure
boundary tests with: python3 Tests/background-dialog-harness-test.py

Normal execution creates one nonce-owned window with an alert tab and a cover
tab. It waits for the CLI's original 30-second timeout, then explicitly focuses
the fixture and reads the real dialog. No JavaScript is used for ownership
checks while an alert is pending. Ambiguous cleanup leaves the fixture intact
and prints its window ID and URL; it never closes a user's window.

Before Safari interaction, the harness identifies the executable's host-arch
Mach-O UUID and proves nested process-group inheritance using only wait 2000.
CLI commands use the UUID-guarded internal worker so their osascript children
remain in the harness-owned group; unsupported builds are refused.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from dialog_ownership import fixture_is_active

ROOT = Path(__file__).resolve().parents[1]
CLI_TIMEOUT = 30
ARM_DELAY = 10


class VerificationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def run(argv, *, timeout=10, env=None):
    # Reap this invocation's owned process group on a harness deadline. CLI
    # callers MUST enable the UUID-guarded MCP context below: ordinary macOS
    # Foundation Process descendants create a new group and escape killpg.
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, env=env, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def session_preflight(checker):
    configured = os.environ.get('DIALOG_TEST_SESSION_CHECK')
    if configured:
        # Same injectable native preflight as e2e-dialog.sh; useful for fake tests.
        checker = Path(configured)
    elif not checker.exists():
        built = run(['clang', str(ROOT / 'Tests/Fixtures/session-lock.c'),
                     '-framework', 'CoreGraphics', '-framework', 'CoreFoundation',
                     '-o', str(checker)], timeout=30)
        require(built.returncode == 0, 'cannot build GUI-session preflight: ' + built.stderr)
    status = run([str(checker)], timeout=3).returncode
    require(status in (0, 77), f'GUI-session preflight failed ({status})')
    return status


def parse_image_identifier(output, architecture):
    require(architecture in ('arm64', 'x86_64'),
            f'unsupported host architecture for fixture isolation: {architecture}')
    rows = output.splitlines()
    require(bool(rows), 'selected browser has no Mach-O UUID')
    identifiers = {}
    pattern = (r'UUID: ([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}) '
               r'\(([^()\s]+)\) (.+)')
    for row in rows:
        match = re.fullmatch(pattern, row)
        require(match is not None, 'unrecognized Mach-O UUID output')
        identifier, arch, _ = match.groups()
        require(arch not in identifiers, f'ambiguous Mach-O UUID for architecture {arch}')
        identifiers[arch] = identifier.replace('-', '').lower()
    require(architecture in identifiers,
            f'selected browser has no UUID for host architecture {architecture}')
    return identifiers[architecture]


def image_identifier(binary):
    require(binary.is_file() and os.access(binary, os.X_OK),
            f'browser binary is not executable: {binary}')
    # Read the selected artifact without executing it or contacting Safari.
    # If replaced later, main's loaded-image guard rejects the stale UUID.
    outcome = run(['/usr/bin/dwarfdump', '--uuid', str(binary)])
    require(outcome.returncode == 0 and not outcome.stderr.strip(),
            'cannot identify selected browser build: ' + outcome.stderr)
    return parse_image_identifier(outcome.stdout, platform.machine())


def verify_timeout(outcome, elapsed):
    require(outcome.returncode != 0, 'background js unexpectedly succeeded')
    require(f'Process timed out after {CLI_TIMEOUT} seconds:' in outcome.stderr,
            'original process timeout is missing: ' + outcome.stderr)
    require(CLI_TIMEOUT - 1 <= elapsed < CLI_TIMEOUT + 15,
            f'expected the original {CLI_TIMEOUT}s wait, got {elapsed:.3f}s')
    lowered = outcome.stderr.lower()
    require(all(part in lowered for part in ('background', 'tab focus', 'dialog list')),
            'background recovery hint is incomplete: ' + outcome.stderr)
    require('BLOCKING DIALOG' not in outcome.stderr,
            'a visible-dialog warning cannot establish a pending background alert')


class Harness:
    def __init__(self, binary, checker, image_id):
        require(re.fullmatch(r'[0-9a-f]{32}', image_id) is not None,
                'fixture isolation requires a verified Mach-O image UUID')
        self.binary = binary
        self.checker = checker
        self.nonce = 'background-' + uuid.uuid4().hex
        fixture = (ROOT / 'Tests/Fixtures/dialog-test.html').as_uri()
        self.url = fixture + '?' + self.nonce + '-alert'
        self.cover_url = fixture + '?' + self.nonce + '-cover'
        self.dialog_text = 'e2e background dialog ' + self.nonce
        self.window_id = None
        self.creation_attempted = False
        self.armed = False
        self.env = dict(os.environ, SAFARI_BROWSER_NAME='fixture-' + self.nonce,
                        SAFARI_BROWSER_NO_DIALOG_PROBE='0', SAFARI_BROWSER_MARK_TAB='0',
                        SAFARI_BROWSER_MCP_DIRECT='1', SAFARI_BROWSER_MCP_IMAGE_ID=image_id)
        self.env.pop('SAFARI_BROWSER_DAEMON', None)
        self.env.pop('SAFARI_BROWSER_DIALOG_PROBE_DEBUG', None)

    def check_session(self):
        return session_preflight(self.checker) == 0

    def cli(self, *args, timeout=10):
        # MCPCommandProcess uses POSIX spawn without SETPGROUP in this context,
        # keeping osascript within run()'s group. The hidden entry also makes an
        # older binary that ignores the environment fail before any command.
        return run([str(self.binary), '__mcp-exec', *args], env=self.env, timeout=timeout)

    def verify_process_group(self):
        # Early MCP builds know the image guard but still launch Foundation
        # descendants in separate groups. Prove this artifact's actual spawn
        # behavior using a duration-only wait; it never resolves a Safari tab.
        confirmed = False
        reason = 'no directly nested wait process was observed'
        with subprocess.Popen([str(self.binary), '__mcp-exec', 'exec'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=self.env,
                              start_new_session=True) as process:
            try:
                process.stdin.write('[{"cmd":"wait","args":["2000"]}]')
                process.stdin.close()
                process.stdin = None
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and process.poll() is None:
                    children = run(['/usr/bin/pgrep', '-P', str(process.pid)], timeout=1)
                    if children.returncode == 1:
                        time.sleep(0.02)
                        continue
                    require(children.returncode == 0, 'cannot inspect nested wait process')
                    ids = children.stdout.split()
                    require(len(ids) == 1 and ids[0].isdigit(), 'nested wait process is ambiguous')
                    child = int(ids[0])
                    parent = run(['/bin/ps', '-p', str(child), '-o', 'ppid='], timeout=1)
                    if parent.returncode or parent.stdout.strip() != str(process.pid):
                        continue
                    try:
                        confirmed = os.getpgid(child) == process.pid
                    except ProcessLookupError:
                        continue
                    reason = 'nested wait process escaped the owned process group'
                    break
            finally:
                if confirmed:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                # An escaping descendant runs only wait 2000. Let it finish;
                # never chase or signal a discovered PID in another group.
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=3)
                    raise VerificationError('duration-only group preflight did not finish')
        require(confirmed, 'browser build cannot guarantee fixture cleanup: ' + reason)

    def target(self, *args, url=None, timeout=10):
        # --window is an index, not an ID, and cannot combine with URL flags.
        # Resolve by exact nonce URL; independently anchor ownership by ID.
        return self.cli(*args, '--url-exact', url or self.url, timeout=timeout)

    def native(self, script):
        outcome = run(['/usr/bin/osascript', '-e', script])
        require(outcome.returncode == 0, 'native fixture check failed: ' + outcome.stderr)
        return outcome.stdout.strip()

    def current_url(self, window_id):
        require(window_id == self.window_id, 'warning belongs to another window')
        return self.native(f'tell application "Safari" to get URL of current tab of window id {window_id}')

    def window_script(self, action='return "owned"'):
        require(isinstance(self.window_id, int) and self.window_id > 0, 'fixture window ID is unknown')
        return f'''tell application "Safari"
            if not (exists window id {self.window_id}) then return "gone"
            set w to window id {self.window_id}
            if (count tabs of w) is not 2 then return "retained"
            if (URL of tab 1 of w) is not {quoted(self.url)} then return "retained"
            if (URL of tab 2 of w) is not {quoted(self.cover_url)} then return "retained"
            {action}
        end tell'''

    def require_owned(self, *, background=False):
        require(self.check_session(), 'GUI session became locked; fixture retained')
        require(self.native(self.window_script()) == 'owned', 'fixture window/URLs changed')
        if background:
            require(self.current_url(self.window_id) == self.cover_url,
                    'fixture alert tab is not in the background')

    def owned_button(self, title, listing):
        if title.returncode or listing.returncode:
            return None
        ids = re.findall(r'^⚠ BLOCKING DIALOG in window id ([1-9][0-9]*):',
                         title.stderr, re.MULTILINE)
        if ids != [str(self.window_id)] or self.dialog_text not in title.stderr:
            return None
        lines = listing.stdout.splitlines()
        if not lines or lines[0] != 'blocking dialog present':
            return None
        if [line for line in lines if line.startswith('  message: ')] != [
                f'  message: "{self.dialog_text}"']:
            return None
        buttons = [line for line in lines if line.startswith('  buttons: ')]
        if len(buttons) != 1:
            return None
        match = re.fullmatch(r'  buttons: "([^"\r\n]+)"', buttons[0])
        if not match or not fixture_is_active(title.stderr, self.url, self.current_url):
            return None
        return match[1]

    def dismiss_owned(self):
        self.require_owned()
        # get title is a native Safari read; JavaScript would remain blocked.
        title = self.target('get', 'title')
        listing = self.cli('dialog', 'list')
        button = self.owned_button(title, listing)
        require(button is not None, 'dialog ownership/text/button is unconfirmed; no button pressed')
        self.require_owned()
        require(self.current_url(self.window_id) == self.url, 'active fixture changed before dismissal')
        dismissed = self.cli('dialog', 'dismiss', '--button', button,
                             '--expect-window-id', str(self.window_id),
                             '--expect-message', self.dialog_text)
        require(dismissed.returncode == 0 and self.dialog_text in dismissed.stdout,
                'owned dialog dismissal was not confirmed: ' + dismissed.stderr)
        self.armed = False

    def exercise(self):
        if run(['/usr/bin/pgrep', '-x', 'Safari'], timeout=3).returncode:
            print('SKIP: Safari is not running; GUI acceptance was not performed.')
            return 77
        initial = self.cli('dialog', 'list')
        if initial.returncode == 0 and initial.stdout.startswith('blocking dialog present'):
            print('SKIP: an existing dialog prevents isolated acceptance; no fixture created.')
            return 77
        require(initial.returncode == 0 and initial.stdout.strip() == 'no blocking dialog found',
                'initial dialog inspection did not establish a clear session: ' + initial.stderr)
        require(self.check_session(), 'GUI session became locked before fixture creation')
        self.creation_attempted = True
        print(f'Creating owned fixture: {self.url}', flush=True)
        self.window_id = int(self.native(f'''tell application "Safari"
            make new document with properties {{URL:{quoted(self.url)}}}
            return id of front window
        end tell'''))
        print(f'Owned window ID: {self.window_id}', flush=True)
        created = self.native(f'''tell application "Safari"
            set w to window id {self.window_id}
            if (count tabs of w) is not 1 then return "retained"
            if (URL of tab 1 of w) is not {quoted(self.url)} then return "retained"
            make new tab at end of tabs of w with properties {{URL:{quoted(self.cover_url)}}}
            return "created"
        end tell''')
        require(created == 'created', 'initial fixture identity changed')
        self.require_owned()
        focused = self.target('tab', 'focus')
        require(focused.returncode == 0, 'cannot focus the owned alert fixture')
        time.sleep(1)
        title = self.target('get', 'title')
        require(title.returncode == 0 and 'Dialog Test Page' in title.stdout,
                'native fixture title was not ready')
        require(self.current_url(self.window_id) == self.url, 'alert fixture is not active')

        started = time.monotonic()
        self.armed = True  # An arming timeout may still have scheduled the alert.
        source = f'(setTimeout(function(){{alert({json.dumps(self.dialog_text)});}}, {ARM_DELAY * 1000}), "armed")'
        armed = self.target('js', source, timeout=45)
        require(armed.returncode == 0 and armed.stdout.strip() == 'armed',
                'alert arming failed; pending state is unknown: ' + armed.stderr)
        self.require_owned()
        cover = self.target('tab', 'focus', url=self.cover_url)
        require(cover.returncode == 0, 'cannot focus owned cover tab')
        self.require_owned(background=True)
        require(time.monotonic() < started + ARM_DELAY,
                'cover focus did not finish before the alert deadline')
        time.sleep(max(0, started + ARM_DELAY + 2 - time.monotonic()))
        invisible = self.cli('dialog', 'list')
        require(invisible.returncode == 0 and invisible.stdout.strip() == 'no blocking dialog found',
                'background pending fixture unexpectedly has a visible/unknown dialog')
        self.require_owned(background=True)
        print('Waiting for the original 30-second CLI timeout on the background alert tab…', flush=True)
        started = time.monotonic()
        outcome = self.target('js', '1+1', timeout=45)
        elapsed = time.monotonic() - started
        verify_timeout(outcome, elapsed)
        print(outcome.stderr.rstrip(), file=sys.stderr, flush=True)
        self.require_owned(background=True)
        invisible = self.cli('dialog', 'list')
        require(invisible.returncode == 0 and invisible.stdout.strip() == 'no blocking dialog found',
                'CLI changed the pending dialog visibility')

        # Recovery is an explicit harness action, after timeout evidence exists.
        focused = self.target('tab', 'focus')
        require(focused.returncode == 0, 'explicit fixture focus failed')
        time.sleep(0.5)
        self.dismiss_owned()
        recovered = self.target('js', '1+1', timeout=45)
        require(recovered.returncode == 0 and recovered.stdout.strip() == '2',
                'fixture JavaScript did not recover after owned dismissal')
        return 0

    def cleanup(self):
        if self.window_id is None:
            return not self.creation_attempted
        try:
            if not self.check_session():
                return False
            ownership = self.native(self.window_script())
            if ownership == 'gone':
                return True
            if ownership != 'owned':
                return False
            if self.armed:
                # Never focus a pending background alert just to clean up. If
                # its visible ownership is unknown, leave the window intact.
                self.dismiss_owned()
            clear = self.cli('dialog', 'list')
            if clear.returncode or clear.stdout.strip() != 'no blocking dialog found':
                return False
            if not self.check_session():
                return False
            return self.native(self.window_script('close w\nreturn "closed"')) in ('closed', 'gone')
        except (VerificationError, OSError, ValueError, subprocess.SubprocessError) as error:
            print(f'Cleanup withheld: {error}', file=sys.stderr)
            return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight-only', action='store_true')
    args = parser.parse_args(argv)
    gui = None
    status = 1
    with tempfile.TemporaryDirectory(prefix='sb-background-dialog-') as directory:
        try:
            checker = Path(directory) / 'session-check'
            # No Safari process check, CLI invocation, or AppleScript precedes this.
            if session_preflight(checker) == 77:
                print('SKIP: GUI session is locked or unavailable; GUI acceptance was not performed.')
                return 77
            if args.preflight_only:
                print('GUI session preflight completed; GUI acceptance was not performed.')
                return 0
            binary = Path(os.environ.get('SAFARI_BROWSER_BIN', ROOT / '.build/debug/safari-browser')).resolve()
            image_id = image_identifier(binary)
            gui = Harness(binary, checker, image_id)
            gui.verify_process_group()
            status = gui.exercise()
        except (VerificationError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            print(f'FAIL: {error}', file=sys.stderr)
        finally:
            if gui is not None and not gui.cleanup():
                status = 1
                print(f'RETAINED fixture: window ID={gui.window_id or "unknown"}; URL={gui.url}; '
                      f'pending alert possible={gui.armed}. Cleanup is incomplete; no acceptance PASS.',
                      file=sys.stderr)
    if status == 0:
        print('PASS: real background timeout hint, explicit focus, owned dialog recovery, and fixture cleanup.')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
