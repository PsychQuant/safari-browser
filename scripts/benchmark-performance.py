#!/usr/bin/env python3
"""Fixed, bounded Safari Browser benchmarks; raw command output is never reported."""
import argparse
import errno
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
import threading
import uuid

PREFIX = b'[safari-browser timing] '
MAX_CAPTURE = 65536
FIXTURE_TITLE = 'Benchmark fixture'
PHASES = frozenset(('command target.resolve target.native applescript.direct applescript.daemon '
    'applescript.inprocess process.spawn process.wait file-dialog.run ax.wait ax.inspect '
    'daemon.request daemon.compile daemon.execute daemon.cache_hit exec.run').split())


def summarize(samples):
    values = sorted(s['wallNanoseconds'] for s in samples if s['status'] == 'ok')
    return {'successful': len(values), 'failed': sum(s['status'] not in ('ok', 'skip') for s in samples),
            'skipped': sum(s['status'] == 'skip' for s in samples),
            'p50Nanoseconds': values[math.ceil(len(values) * .5) - 1] if values else None,
            'p95Nanoseconds': values[math.ceil(len(values) * .95) - 1] if values else None}


def integer(value):
    return type(value) is int and 0 <= value <= 2**64 - 1


def parse_trace(data, process_id=None):
    """Select an unambiguous root and reconstruct only safe typed fields."""
    if len(data) > MAX_CAPTURE:
        return None
    lines = [line[len(PREFIX):] for line in data.splitlines() if line.startswith(PREFIX)]
    if not lines or len(lines) > 64:
        return None
    try:
        summaries = [sanitize_trace(json.loads(line)) for line in lines]
    except (ValueError, TypeError, RecursionError):
        return None
    if any(summary is None for summary in summaries):
        return None
    if len(summaries) == 1:
        summary = summaries[0]
        return summary if process_id is None or summary.get('processID', process_id) == process_id else None
    if process_id is None:
        return None
    roots = [summary for summary in summaries if summary.get('processID') == process_id]
    return roots[0] if len(roots) == 1 else None


def sanitize_trace(obj):
    try:
        if not isinstance(obj, dict) or type(obj.get('schemaVersion')) is not int or obj['schemaVersion'] != 1:
            return None
        pid = obj.get('processID')
        if 'processID' in obj and (type(pid) is not int or not 1 <= pid <= 2**31 - 1):
            return None
        request_id = str(uuid.UUID(obj['requestID']))
        if obj['status'] not in ('ok', 'error') or not integer(obj['totalNanoseconds']) or not integer(obj['droppedSpans']):
            return None
        if not isinstance(obj['spans'], list) or len(obj['spans']) > 64:
            return None
        spans, seen = [], set()
        for span in obj['spans']:
            if not isinstance(span, dict) or not integer(span['id']) or not 1 <= span['id'] <= 64 or span['id'] in seen:
                return None
            parent = span.get('parentID')
            if parent is not None and (not integer(parent) or not 1 <= parent <= 64 or parent not in seen):
                return None
            if span['phase'] not in PHASES or span['outcome'] not in ('ok', 'error', 'unfinished') or not integer(span['durationNanoseconds']):
                return None
            safe = {key: span[key] for key in ('id', 'phase', 'durationNanoseconds', 'outcome')}
            if parent is not None:
                safe['parentID'] = parent
            spans.append(safe)
            seen.add(span['id'])
        result = {'schemaVersion': 1, 'requestID': request_id, 'status': obj['status'],
                'totalNanoseconds': obj['totalNanoseconds'], 'droppedSpans': obj['droppedSpans'], 'spans': spans}
        if pid is not None:
            result['processID'] = pid
        return result
    except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
        return None


def require_waitid():
    if not callable(getattr(os, 'waitid', None)) or any(not hasattr(os, key) for key in ('P_PID', 'WNOWAIT', 'WEXITED', 'WNOHANG')):
        raise OSError('Non-reaping child observation is unavailable')


def observe_exit(process):
    """Observe without reaping: the waitable leader reserves its PID and PGID."""
    if process.returncode is not None:
        raise ChildProcessError('Owned process leader was already reaped')
    state = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if state is None:
        return None
    return state.si_status if state.si_code == os.CLD_EXITED else -state.si_status


class ExitObservation:
    """Capture the kernel exit notification time without releasing child identity."""
    def __init__(self, process):
        self.process = process
        self.completed_ns = None
        self.exit_code = None
        self.failed = False
        self.finished = threading.Event()
        self.read_fd, self.write_fd = os.pipe()
        self.pipe_lock = threading.Lock()
        self.thread = threading.Thread(target=self._wait, daemon=True)
        self.thread.start()

    def _wait(self):
        try:
            state = os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOWAIT)
            self.completed_ns = time.monotonic_ns()
            self.exit_code = state.si_status if state.si_code == os.CLD_EXITED else -state.si_status
        except OSError:
            self.failed = True
        finally:
            self.finished.set()
            with self.pipe_lock:
                if self.write_fd is not None:
                    try:
                        os.write(self.write_fd, b'1')
                    finally:
                        os.close(self.write_fd)
                        self.write_fd = None

    def join_before_reap(self):
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise OSError('Child exit observer did not finish')

    def close(self):
        # Closing the notification channel must not wait for an unkillable
        # child. The writer uses the same lock, so a reused fd is never used.
        with self.pipe_lock:
            for name in ('read_fd', 'write_fd'):
                descriptor = getattr(self, name)
                if descriptor is not None:
                    os.close(descriptor)
                    setattr(self, name, None)


def signal_owned_group(process):
    # ECHILD is an ownership failure, not permission to signal a recycled PID.
    observe_exit(process)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin reports EPERM for a group containing only zombies. WNOWAIT
        # still pins the original leader identity; pgrep is used only to
        # confirm there are no live group members, never to infer ownership.
        # The leader can exit between the ownership check and killpg. Refresh
        # its still-unreaped state before classifying this particular EPERM.
        if sys.platform != 'darwin' or observe_exit(process) is None:
            raise
        check = subprocess.run(['/usr/bin/pgrep', '-g', str(process.pid)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
        if check.returncode != 1:
            raise


def kill_group(process, *, group_signalled=False, observer=None):
    """Signal the owned group before the only operation that reaps its leader."""
    observe_exit(process)
    if not group_signalled:
        signal_owned_group(process)
    if observer is not None:
        observer.join_before_reap()
    process.wait(timeout=2)


def close_process_streams(process):
    failed = False
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except (OSError, ValueError):
                failed = True
    return not failed


def mark_cleanup_failed(result):
    result['cleanupFailed'] = True
    if 'samples' in result:
        for sample in result['samples'] + result['warmups']:
            mark_cleanup_failed(sample)
        result['statistics'] = summarize(result['samples'])
    else:
        result['status'] = 'error'
        result.setdefault('reason', 'cleanup_failed')


def run_process(argv, env, timeout, *, capture_stdout=False):
    started = time.monotonic_ns()
    captured = {'stderr': bytearray(), 'stdout': bytearray()}
    truncated = {'stderr': False, 'stdout': False}
    process = None
    observer = None
    status = 'error'
    completion_wall = None
    descendants_stopped = False
    cleanup_failed = False
    try:
        require_waitid()
        process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
            stderr=subprocess.PIPE, start_new_session=True)
        observer = ExitObservation(process)
        deadline = started / 1e9 + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(observer.read_fd, selectors.EVENT_READ, 'exit')
            selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
            if capture_stdout:
                selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
            leader_exit = None
            while True:
                if observer.finished.is_set():
                    if observer.failed:
                        raise OSError('Child exit observation failed')
                    leader_exit = observer.exit_code
                if leader_exit is not None and not descendants_stopped:
                    completion_wall = observer.completed_ns - started
                    # Orphans may retain pipe handles. Stop them while keeping
                    # the exited leader unreaped, then drain buffered output.
                    signal_owned_group(process)
                    descendants_stopped = True
                if leader_exit is not None and not selector.get_map():
                    status = 'timeout' if completion_wall > timeout * 1e9 else ('ok' if leader_exit == 0 else 'error')
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    status = 'timeout'
                    break
                for key, _ in selector.select(remaining):
                    if key.data == 'exit':
                        os.read(observer.read_fd, 1)
                        selector.unregister(observer.read_fd)
                        continue
                    data = os.read(key.fileobj.fileno(), 8192)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    kind = key.data
                    available = MAX_CAPTURE - len(captured[kind])
                    captured[kind].extend(data[:available])
                    truncated[kind] |= len(data) > available
    except (OSError, ValueError, subprocess.SubprocessError):
        status = 'error'
    finally:
        elapsed = completion_wall if completion_wall is not None and status != 'timeout' else time.monotonic_ns() - started
        if process is not None:
            try:
                kill_group(process, group_signalled=descendants_stopped, observer=observer)
            except (OSError, subprocess.SubprocessError):
                cleanup_failed = True
            finally:
                try:
                    if observer:
                        observer.close()
                except (OSError, ValueError):
                    cleanup_failed = True
                finally:
                    if not close_process_streams(process):
                        cleanup_failed = True
    result = {'status': status, 'wallNanoseconds': elapsed,
              'exitCode': process.returncode if process is not None else None,
              'daemonFallback': b'[daemon fallback:' in captured['stderr'],
              'trace': parse_trace(bytes(captured['stderr']), process_id=process.pid if process else None), 'stderrTruncated': truncated['stderr']}
    if cleanup_failed:
        mark_cleanup_failed(result)
    if capture_stdout:
        # Internal ownership/protocol checks only. Never included in a report.
        return result, bytes(captured['stdout']) if not truncated['stdout'] else b''
    return result



def isolated_environment(directory, timing):
    env = {key: value for key, value in os.environ.items() if not key.startswith('SAFARI_BROWSER_')}
    env.update(TMPDIR=directory, SAFARI_BROWSER_NAME='bench-' + uuid.uuid4().hex[:12],
               SAFARI_BROWSER_TRACE_TIMING='1' if timing else '0')
    return env


class ServiceCleanupError(OSError):
    """Service startup failed and its owned cleanup could not be confirmed."""


class Service:
    """An owned foreground daemon or MCP host. No daemon start/stop discovery."""
    def __init__(self, binary, env, kind, timeout):
        self.kind, self.timeout = kind, timeout
        self.process = None
        self.pending = bytearray()
        self.cleanup_failed = False
        self.identifier = 0
        self.selector = selectors.DefaultSelector()
        self.started = time.monotonic_ns()
        try:
            require_waitid()
            args = ['mcp', '--timeout', str(timeout)] if kind == 'mcp' else ['daemon', '__serve', '--name', env['SAFARI_BROWSER_NAME'], '--socket-dir', env['TMPDIR']]
            self.process = subprocess.Popen([binary, *args], env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE if kind == 'mcp' else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
            if kind == 'mcp':
                self.selector.register(self.process.stdout, selectors.EVENT_READ, 'stdout')
                reply = self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                    'clientInfo': {'name': 'benchmark', 'version': '1'}}, self.started / 1e9 + timeout)
                if not isinstance(reply.get('result'), dict) or reply['result'].get('protocolVersion') != '2025-11-25':
                    raise ValueError('protocol')
                self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            else:
                path = Path(env['TMPDIR'], 'safari-browser-' + env['SAFARI_BROWSER_NAME'] + '.sock')
                deadline = self.started / 1e9 + timeout
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError()
                    if observe_exit(self.process) is not None:
                        raise ValueError('host_exit')
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                        probe.settimeout(remaining)
                        try:
                            probe.connect(str(path))
                        except OSError as error:
                            if error.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                                raise
                            self.drain(min(.01, max(0, deadline - time.monotonic())))
                            continue
                        # The host writes first. Drain its bounded handshake
                        # before closing to avoid interrupting its initial write.
                        # Once connected, any unknown outcome fails without
                        # reconnecting; never send a handler request.
                        self.read_daemon_handshake(probe, deadline)
                    break
        except BaseException as error:
            if not self.close() and isinstance(error, Exception):
                raise ServiceCleanupError() from error
            raise
        self.setup_nanoseconds = time.monotonic_ns() - self.started

    @staticmethod
    def read_daemon_handshake(probe, deadline):
        buffered = bytearray()
        while len(buffered) < MAX_CAPTURE:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            probe.settimeout(remaining)
            chunk = probe.recv(min(4096, MAX_CAPTURE - len(buffered)))
            if not chunk:
                raise ValueError('daemon_handshake_incomplete')
            buffered.extend(chunk)
            if b'\n' in buffered:
                try:
                    hello = json.loads(buffered.split(b'\n', 1)[0])
                    if not isinstance(hello, dict) or not isinstance(hello.get('protocol'), dict):
                        raise ValueError()
                    if hello['protocol'].get('name') != 'persistent-daemon':
                        raise ValueError()
                except (ValueError, TypeError, RecursionError):
                    raise ValueError('daemon_handshake_invalid') from None
                return
        raise ValueError('daemon_handshake_limit')

    def drain(self, wait):
        for key, _ in self.selector.select(wait):
            data = os.read(key.fileobj.fileno(), 8192)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            if key.data == 'stdout':
                self.pending.extend(data)
                # MCP responses duplicate stdout/stderr in content; bound the whole frame.
                if len(self.pending) > 1024 * 1024:
                    raise ValueError('frame_limit')

    def send(self, request):
        self.process.stdin.write(json.dumps(request).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params, deadline):
        self.identifier += 1
        self.send({'jsonrpc': '2.0', 'id': self.identifier, 'method': method, 'params': params})
        while b'\n' not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            if observe_exit(self.process) is not None:
                raise ValueError('host_exit')
            self.drain(min(remaining, .05))
        line, _, rest = self.pending.partition(b'\n')
        self.pending = bytearray(rest)
        try:
            reply = json.loads(line)
        except RecursionError as error:
            raise ValueError('protocol') from error
        if not isinstance(reply, dict) or type(reply.get('id')) is not int or reply['id'] != self.identifier:
            raise ValueError('protocol')
        return reply

    def call_wait(self, deadline):
        started = time.monotonic_ns()
        result = {'status': 'error', 'trace': None, 'stderrTruncated': False, 'exitCode': None}
        try:
            reply = self.request('tools/call', {'name': 'safari.wait',
                'arguments': {'positionals': {'milliseconds': '0'}}}, deadline)
            tool = reply.get('result', {})
            content = tool.get('structuredContent', {})
            code = content.get('exit_code')
            if type(code) is int:
                result['exitCode'] = code
            if tool.get('isError') is False and content.get('capture_complete') is True and type(code) is int and code == 0 and content.get('failure') is None:
                result['status'] = 'ok'
            err = content.get('stderr', {})
            if err.get('encoding') == 'utf-8' and isinstance(err.get('data'), str):
                data = err['data'].encode()
                result['trace'] = parse_trace(data[:MAX_CAPTURE])
                result['stderrTruncated'] = len(data) > MAX_CAPTURE
        except TimeoutError:
            result['status'] = 'timeout'
        except (ValueError, OSError, AttributeError, TypeError, RecursionError):
            pass
        result['wallNanoseconds'] = time.monotonic_ns() - started
        return result

    def close(self):
        try:
            if self.process is not None:
                if self.process.stdin and not self.process.stdin.closed:
                    try:
                        self.process.stdin.close()
                    except OSError:
                        self.cleanup_failed = True
                # EOF lets MCP cancel its workers before we signal the host.
                if self.kind == 'mcp':
                    deadline = time.monotonic() + 2
                    while observe_exit(self.process) is None and time.monotonic() < deadline:
                        time.sleep(.01)
                kill_group(self.process)
        except (OSError, subprocess.SubprocessError):
            self.cleanup_failed = True
        finally:
            if self.process is not None:
                if not close_process_streams(self.process):
                    self.cleanup_failed = True
                self.process = None
            try:
                self.selector.close()
            except (OSError, ValueError):
                self.cleanup_failed = True
        return not self.cleanup_failed


def scenario_report(name, timing, samples, warmups, measure, setup=None):
    warmup_results = [measure() for _ in range(warmups)]
    results = [measure() for _ in range(samples)]
    report = {'name': name, 'timing': 'on' if timing else 'off', 'sampleCount': samples,
              'warmupCount': warmups, 'warmups': warmup_results, 'samples': results,
              'statistics': summarize(results)}
    if setup is not None:
        report['serviceSetupNanoseconds'] = setup
    if any(sample.get('cleanupFailed') for sample in results + warmup_results):
        mark_cleanup_failed(report)
    return report


def failure(reason, status='error'):
    return {'status': status, 'reason': reason, 'wallNanoseconds': None, 'trace': None}


def valid_daemon_status(output, name, process_id):
    """Validate the fixed CLI status shape and owned host PID without exporting it."""
    pattern = (
        rb'daemon ' + re.escape(name.encode()) + rb':\n'
        rb'  pid: +' + str(process_id).encode() + rb'\n'
        rb'  uptime: +[0-9]+s\n'
        rb'  requests served: +[0-9]+\n'
        rb'  pre-compiled scripts: +[0-9]+\n'
    )
    return re.fullmatch(pattern, output) is not None


def service_scenario(binary, kind, cold, timing, samples, warmups, timeout):
    operation = 'status' if kind == 'daemon' else 'wait'
    name = f'{kind}.cold-host-{operation}-including-startup' if cold else f'{kind}.warm-host-fresh-worker'
    if kind == 'daemon':
        name = name.replace('worker', 'cli-status')
    service = None
    with tempfile.TemporaryDirectory(prefix='sb-bench-', dir='/tmp') as directory:
        env = isolated_environment(directory, timing)
        def measure():
            nonlocal service
            started = time.monotonic_ns()
            owned_directory = None
            result = None
            try:
                current_env = env
                if cold:
                    owned_directory = tempfile.TemporaryDirectory(prefix='sb-bench-', dir='/tmp')
                    current_env = isolated_environment(owned_directory.name, timing)
                    service = Service(binary, current_env, kind, timeout)
                if service is None or observe_exit(service.process) is not None:
                    result = failure('service_unavailable')
                    return result
                deadline = started / 1e9 + timeout
                before_request = time.monotonic_ns() - started
                if kind == 'mcp':
                    result = service.call_wait(deadline)
                else:
                    result, output = run_process([binary, 'daemon', 'status', '--name', current_env['SAFARI_BROWSER_NAME'],
                                                 '--socket-dir', current_env['TMPDIR']], current_env,
                                                max(.001, deadline - time.monotonic()), capture_stdout=True)
                    if result['status'] == 'ok' and not valid_daemon_status(
                            output, current_env['SAFARI_BROWSER_NAME'], service.process.pid):
                        result['status'] = 'error'
                        result['reason'] = 'daemon_status_invalid'
                    if observe_exit(service.process) is not None:
                        result['status'] = 'error'
                        result['reason'] = 'service_exited'
                if cold:
                    result['wallNanoseconds'] += before_request
                # A failed call is never retried or sent to a replacement warm host.
                if result['status'] != 'ok' and not cold:
                    if not service.close():
                        mark_cleanup_failed(result)
                    service = None
                return result
            except TimeoutError:
                result = failure('service_start_timeout', 'timeout')
                return result
            except (OSError, ValueError, TypeError) as error:
                result = failure('service_start_failed')
                if isinstance(error, ServiceCleanupError):
                    mark_cleanup_failed(result)
                return result
            finally:
                if cold and service is not None:
                    if not service.close() and result is not None:
                        mark_cleanup_failed(result)
                    service = None
                if owned_directory:
                    owned_directory.cleanup()
        report = None
        try:
            if not cold:
                try:
                    service = Service(binary, env, kind, timeout)
                except (OSError, ValueError, TimeoutError, TypeError) as error:
                    report = scenario_report(name, timing, samples, warmups, lambda: failure('service_start_failed'))
                    if isinstance(error, ServiceCleanupError):
                        mark_cleanup_failed(report)
                    return report
            report = scenario_report(name, timing, samples, warmups, measure,
                                     setup=service.setup_nanoseconds if service else None)
            return report
        finally:
            if service is not None:
                if not service.close() and report is not None:
                    mark_cleanup_failed(report)


def benchmark(binary, *, samples, warmups, timeout, timing='both', live=False):
    digest = hashlib.sha256()
    with open(binary, 'rb') as executable:
        for block in iter(lambda: executable.read(1024 * 1024), b''):
            digest.update(block)
    os_build = platform.release()
    if sys.platform == 'darwin':
        try:
            os_build = subprocess.check_output(['/usr/bin/sw_vers', '-buildVersion'], timeout=2).decode().strip()
        except (OSError, subprocess.SubprocessError):
            os_build = 'unavailable'
    report = {'schemaVersion': 1, 'environment': {'binarySHA256': digest.hexdigest(),
        'os': platform.system(), 'osBuild': os_build, 'architecture': platform.machine()},
        'measurement': {'clock': 'monotonic', 'wallIncludesLoader': True, 'osCachesCleared': False,
            'quantiles': 'nearest-rank-successful-samples', 'spanDurations': 'inclusive-do-not-sum',
            'coldHostWall': 'startup-readiness-and-one-request-excludes-cleanup',
            'warmHostWall': 'one-request-excludes-host-startup'}, 'scenarios': []}
    for enabled in ([False, True] if timing == 'both' else [timing == 'on']):
        with tempfile.TemporaryDirectory(prefix='sb-bench-', dir='/tmp') as directory:
            env = isolated_environment(directory, enabled)
            script = Path(directory, 'wait.json')
            script.write_text(json.dumps([{'cmd': 'wait', 'args': ['0']}] * 3))
            for name, args in [('startup.fresh-process-help', ['--help']),
                               ('wait.fresh-process', ['wait', '0']),
                               ('exec.fresh-process-wait-batch', ['exec', '--script', str(script)])]:
                report['scenarios'].append(scenario_report(name, enabled, samples, warmups,
                    lambda args=args: run_process([binary, *args], env, timeout)))
        for kind in ('daemon', 'mcp'):
            for cold in (True, False):
                report['scenarios'].append(service_scenario(binary, kind, cold, enabled, samples, warmups, timeout))
        if live:
            report['scenarios'].extend(live_scenarios(binary, enabled, samples, warmups, timeout))
        else:
            report['scenarios'].extend(live_skip_reports(enabled, samples, warmups, 'live_not_requested'))
    return report



def dialog_clear(result, output):
    return result['status'] == 'ok' and output.strip() == b'no blocking dialog found'


def fixture_url(url):
    if not isinstance(url, str) or re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}/[0-9a-f]{16,32}/', url) is None:
        raise ValueError('invalid_fixture_url')
    return json.dumps(url)


def window_script(window_id, url, close=False, read_title=False):
    if type(window_id) is not int or window_id <= 0:
        raise ValueError('invalid_window_id')
    quoted = fixture_url(url)
    action = 'return name of tab 1 of w' if read_title else 'return "owned"'
    if close:
        action = 'close w\nreturn "closed"'
    # Failure to inspect sheets fails closed; no hidden dialog is dismissed.
    return f'''considering case
    tell application "System Events"
        if not (exists process "Safari") then return "gone"
        tell process "Safari"
            repeat with candidate in windows
                if (count sheets of candidate) is not 0 then return "retained"
            end repeat
        end tell
    end tell
    tell application "Safari"
        if not (exists window id {window_id}) then return "gone"
        set w to window id {window_id}
        if (count tabs of w) is not 1 then return "retained"
        if (URL of tab 1 of w) is not {quoted} then return "retained"
        {action}
    end tell
    end considering'''


def live_skip_reports(timing, samples, warmups, reason, status='skip'):
    return [scenario_report('live.' + mode + '.get-' + operation, timing, samples, warmups,
                            lambda: failure(reason, status))
            for mode in ('direct-fresh-process', 'warm-daemon-fresh-process') for operation in ('title', 'url')]


def live_scenarios(binary, timing, samples, warmups, timeout):
    reports = []
    with tempfile.TemporaryDirectory(prefix='sb-bench-', dir='/tmp') as directory:
        env = isolated_environment(directory, timing)
        def clear():
            result, output = run_process([binary, 'dialog', 'list'], env, timeout, capture_stdout=True)
            return dialog_clear(result, output)
        if not clear():
            return live_skip_reports(timing, samples, warmups, 'gui_preflight_not_clear')
        class FixtureHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = f'<!doctype html><meta charset="utf-8"><title>{FIXTURE_TITLE}</title><p>Read-only benchmark fixture</p>'.encode()
                self.send_response(200 if self.path == route else 404)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        route = '/' + uuid.uuid4().hex + '/'
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        url = f'http://127.0.0.1:{server.server_port}{route}'
        window_id = None
        attempted = False
        cleanup = 'not-created'
        def native(source, deadline=None):
            remaining = timeout if deadline is None else deadline - time.monotonic()
            if remaining <= 0:
                return 'unknown'
            result, output = run_process(['/usr/bin/osascript', '-e', source], env, remaining, capture_stdout=True)
            return output.decode('utf-8', errors='replace').strip() if result['status'] == 'ok' else 'unknown'
        def owned():
            return window_id is not None and native(window_script(window_id, url)) == 'owned'
        def wait_ready():
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                # The same native read verifies ID, exact URL, one tab and
                # absence of sheets before observing this fixture's title.
                title = native(window_script(window_id, url, read_title=True), deadline)
                if title == FIXTURE_TITLE:
                    return None
                if title in ('gone', 'retained'):
                    return 'fixture_ownership_changed'
                time.sleep(min(.02, max(0, deadline - time.monotonic())))
            return 'fixture_readiness_timeout'
        try:
            # Recheck immediately before the only create attempt.
            if not clear():
                reports = live_skip_reports(timing, samples, warmups, 'gui_preflight_not_clear')
                return reports
            attempted = True
            answer = native(f'''considering case
            tell application "Safari"
                make new document with properties {{URL:{fixture_url(url)}}}
                set w to front window
                if (count tabs of w) is not 1 then return "unknown"
                if (URL of tab 1 of w) is not {fixture_url(url)} then return "unknown"
                return id of w
            end tell
            end considering''')
            if answer.isdecimal() and int(answer) > 0:
                window_id = int(answer)
            problem = None if owned() else 'fixture_creation_or_ownership_unknown'
            if problem is None:
                problem = wait_ready()
            if problem is not None:
                reports = live_skip_reports(timing, samples, warmups, problem, 'error')
            else:
                for mode in ('direct-fresh-process', 'warm-daemon-fresh-process'):
                    service = None
                    service_error = None
                    service_failure = None
                    sample_env = dict(env)
                    if mode == 'warm-daemon-fresh-process':
                        sample_env['SAFARI_BROWSER_DAEMON'] = '1'
                    try:
                        if mode == 'warm-daemon-fresh-process':
                            try:
                                service = Service(binary, env, 'daemon', timeout)
                            except (OSError, ValueError, TimeoutError) as error:
                                service_error = error
                        for operation in ('title', 'url'):
                            def measure(operation=operation):
                                nonlocal service_failure
                                if service_failure is not None:
                                    return failure(service_failure)
                                if service_error is not None:
                                    result = failure('service_start_failed')
                                    if isinstance(service_error, ServiceCleanupError):
                                        mark_cleanup_failed(result)
                                    return result
                                if service is not None and observe_exit(service.process) is not None:
                                    service_failure = 'service_exited'
                                    return failure(service_failure)
                                if not owned():
                                    return failure('fixture_ownership_changed')
                                # Ownership inspection can take time. Recheck
                                # the unreaped host immediately before the CLI.
                                if service is not None and observe_exit(service.process) is not None:
                                    service_failure = 'service_exited'
                                    return failure(service_failure)
                                result, output = run_process([binary, 'get', operation, '--url-exact', url],
                                    sample_env, timeout, capture_stdout=True)
                                expected = FIXTURE_TITLE if operation == 'title' else url
                                if result['status'] == 'ok' and output != (expected + '\n').encode():
                                    result['status'] = 'error'
                                    result['reason'] = 'fixture_output_mismatch'
                                if not owned():
                                    result['status'] = 'error'
                                    result['reason'] = 'fixture_ownership_changed'
                                if service is not None:
                                    if observe_exit(service.process) is not None:
                                        service_failure = 'service_exited'
                                    elif result['daemonFallback']:
                                        service_failure = 'daemon_fallback'
                                    elif result['stderrTruncated']:
                                        service_failure = 'daemon_route_unconfirmed'
                                    if service_failure is not None:
                                        # Never restart or retry an ambiguous
                                        # warm path, including later samples.
                                        result['status'] = 'error'
                                        result['reason'] = service_failure
                                return result
                            reports.append(scenario_report('live.' + mode + '.get-' + operation,
                                timing, samples, warmups, measure,
                                setup=service.setup_nanoseconds if service else None))
                    finally:
                        if service and not service.close():
                            for row in reports:
                                if row['name'].startswith('live.' + mode + '.'):
                                    mark_cleanup_failed(row)
        finally:
            # One guarded close only. Unknown outcomes and changed windows are
            # retained; never find another window by URL and never retry close.
            if attempted:
                cleanup = 'retained-ownership-or-outcome-unknown'
                if window_id is not None and clear():
                    answer = native(window_script(window_id, url, close=True))
                    if answer in ('closed', 'gone'):
                        cleanup = answer
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
            for report in reports:
                report['fixtureCleanup'] = cleanup
                if cleanup.startswith('retained'):
                    mark_cleanup_failed(report)
        return reports


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default includes user-supplied values and private paths.
        self.exit(2, 'Invalid benchmark arguments; use --help for supported options.\n')


def main(argv=None):
    parser = PrivateArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='.build/debug/safari-browser', help='Executable to measure (only its digest is reported).')
    parser.add_argument('--samples', type=int, default=5, help='Measured samples per scenario, 1–1000.')
    parser.add_argument('--warmups', type=int, default=1, help='Unmeasured warmups per scenario, 0–100.')
    parser.add_argument('--timeout', type=float, default=10, help='Per-sample wall deadline in seconds, 0.01–120.')
    parser.add_argument('--timing', choices=('on', 'off', 'both'), default='both', help='Trace on/off comparison; default both.')
    parser.add_argument('--live', action='store_true', help='Opt in to an owned localhost Safari fixture; requires an explicitly clear GUI session.')
    args = parser.parse_args(argv)
    if not (1 <= args.samples <= 1000 and 0 <= args.warmups <= 100 and math.isfinite(args.timeout) and .01 <= args.timeout <= 120):
        parser.error('bounds')
    try:
        binary = str(Path(args.binary).resolve(strict=True))
        report = benchmark(binary, samples=args.samples, warmups=args.warmups, timeout=args.timeout,
                           timing=args.timing, live=args.live)
    except (OSError, ValueError, subprocess.SubprocessError):
        sys.stderr.write('Benchmark could not complete; executable or environment unavailable.\n')
        return 2
    except KeyboardInterrupt:
        sys.stderr.write('Benchmark interrupted; owned process cleanup attempted.\n')
        return 130
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write('\n')
    return 1 if any(row['statistics']['failed'] or any(w['status'] not in ('ok', 'skip') for w in row['warmups'])
                    or row.get('cleanupFailed') for row in report['scenarios']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
