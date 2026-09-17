#!/usr/bin/env python3
"""Safari-free behavioral tests for the bounded performance benchmark."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('benchmark', ROOT / 'scripts/benchmark-performance.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def trace(**changes):
    value = {'schemaVersion': 1, 'requestID': '01234567-89ab-4cde-8fab-0123456789ab',
             'status': 'ok', 'totalNanoseconds': 200, 'droppedSpans': 0,
             'spans': [{'id': 1, 'phase': 'command', 'durationNanoseconds': 150, 'outcome': 'ok'}]}
    value.update(changes)
    return value


def stderr(value):
    return b'private /Users/person/token\n[safari-browser timing] ' + json.dumps(value).encode() + b'\n'


class StatisticsTests(unittest.TestCase):
    def test_nearest_rank_and_failures_excluded(self):
        samples = [{'status': 'ok', 'wallNanoseconds': n} for n in [50, 10, 40, 20, 30]]
        samples += [{'status': 'timeout', 'wallNanoseconds': 900}, {'status': 'skip'}]
        result = bench.summarize(samples)
        self.assertEqual((result['p50Nanoseconds'], result['p95Nanoseconds']), (30, 50))
        self.assertEqual((result['successful'], result['failed'], result['skipped']), (5, 1, 1))

    def test_no_success_is_null_not_zero(self):
        self.assertEqual(bench.summarize([{'status': 'error'}])['p50Nanoseconds'], None)
        self.assertEqual(bench.summarize([])['p95Nanoseconds'], None)


class TraceTests(unittest.TestCase):
    def test_whitelist_removes_unknown_private_fields(self):
        value = trace(url='https://secret', path='/Users/private')
        value['spans'][0]['source'] = 'private source'
        result = bench.parse_trace(stderr(value))
        self.assertEqual(result, trace())
        self.assertNotIn('private', json.dumps(result))

    def test_selects_unique_actual_process_root_from_child_traces(self):
        root = trace(processID=123, totalNanoseconds=900, secret='/private/root')
        data = stderr(trace(processID=456)) + stderr(trace(processID=789)) + stderr(root)
        expected = dict(root)
        del expected['secret']
        self.assertEqual(bench.parse_trace(data, process_id=123), expected)
        self.assertIsNone(bench.parse_trace(data, process_id=999))
        self.assertIsNone(bench.parse_trace(data))
        self.assertIsNone(bench.parse_trace(data + stderr(root), process_id=123))
        self.assertIsNone(bench.parse_trace(stderr(trace(processID=123, status='error')) + stderr(root), process_id=123))
        self.assertIsNone(bench.parse_trace(stderr(trace()) * 3, process_id=123))
        self.assertEqual(bench.parse_trace(stderr(trace()), process_id=123), trace())
        self.assertIsNone(bench.parse_trace(stderr(trace(processID=456)), process_id=123))

    def test_rejects_invalid_process_identity_even_in_single_trace(self):
        for pid in (True, False, 0, -1, 2**31, '123', None):
            with self.subTest(pid=pid):
                self.assertIsNone(bench.parse_trace(stderr(trace(processID=pid))))
        self.assertEqual(bench.parse_trace(stderr(trace(processID=2**31 - 1))), trace(processID=2**31 - 1))

    def test_span_ids_are_one_through_64_and_parents_precede_children(self):
        root = trace()['spans'][0]
        for spans in ([dict(root, id=0)], [dict(root, id=65)], [dict(root, id=True)],
                      [root, root], [dict(root, id=2, parentID=1), root],
                      [root, dict(root, id=2, parentID=True)],
                      [root, dict(root, id=2, parentID=0)]):
            with self.subTest(spans=spans):
                self.assertIsNone(bench.parse_trace(stderr(trace(spans=spans))))
        valid = trace(spans=[root, dict(root, id=64, parentID=1)])
        self.assertEqual(bench.parse_trace(stderr(valid)), valid)

    def test_rejects_malformed_type_confusion_cycles_and_oversize(self):
        for value in [trace(schemaVersion=True), trace(totalNanoseconds=True), trace(requestID='/private'),
                      trace(totalNanoseconds=-1), trace(spans=[{'id': 1, 'parentID': 1, 'phase': 'command',
                          'durationNanoseconds': 1, 'outcome': 'ok'}]), trace(spans=trace()['spans'] * 65),
                      trace(spans=[{'id': 1, 'phase': '/private', 'durationNanoseconds': 1, 'outcome': 'ok'}])]:
            with self.subTest(value=value):
                self.assertIsNone(bench.parse_trace(stderr(value)))
        self.assertIsNone(bench.parse_trace(stderr(trace(padding='x' * 70000))))
        self.assertIsNone(bench.parse_trace(stderr(trace()) + stderr(trace())))


class ProcessTests(unittest.TestCase):
    def test_run_process_selects_its_actual_pid_trace(self):
        source = 'import os,sys,json\nt=' + repr(trace()) + "\nfor p,n in [(os.getpid()+1,1),(os.getpid()+2,2),(os.getpid(),333)]:\n t.update(processID=p,totalNanoseconds=n)\n sys.stderr.write('[safari-browser timing] '+json.dumps(t)+'\\n')\n"
        result = bench.run_process([sys.executable, '-c', source], dict(os.environ), 2)
        self.assertEqual(result['status'], 'ok')
        self.assertIsNotNone(result['trace'])
        self.assertEqual(result['trace']['totalNanoseconds'], 333)
        self.assertGreater(result['trace']['processID'], 0)

    def test_closed_stderr_short_process_wall_has_no_50ms_polling_penalty(self):
        results = [bench.run_process(['/bin/sh', '-c', 'exec 2>&-; sleep 0.005'], dict(os.environ), 2) for _ in range(3)]
        self.assertTrue(all(r['status'] == 'ok' for r in results))
        median = sorted(r['wallNanoseconds'] for r in results)[1]
        self.assertLess(median, 35_000_000)
        self.assertGreater(median, 4_000_000)

    def test_reaped_leader_is_never_used_as_group_identity(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        process.wait(timeout=2)
        with mock.patch.object(bench.os, 'killpg') as send:
            with self.assertRaises(ChildProcessError):
                bench.kill_group(process)
            send.assert_not_called()

    def test_darwin_permission_error_is_not_ignored_when_live_group_check_is_uncertain(self):
        for check_status in (0, 2):
            with self.subTest(check_status=check_status):
                process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
                try:
                    os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
                    with mock.patch.object(bench.os, 'killpg', side_effect=PermissionError()), \
                            mock.patch.object(bench.subprocess, 'run', return_value=subprocess.CompletedProcess([], check_status)):
                        with self.assertRaises(PermissionError):
                            bench.signal_owned_group(process)
                finally:
                    process.wait(timeout=2)

    def test_natural_exit_retains_waitable_leader_until_group_signal(self):
        observed = []
        actual_killpg = os.killpg
        def require_owned(pgid, sig):
            try:
                state = os.waitid(os.P_PID, pgid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            except ChildProcessError:
                observed.append(False)
                return  # Never signal a group whose original leader was reaped.
            observed.append(True)
            actual_killpg(pgid, sig)
        with mock.patch.object(bench.os, 'killpg', require_owned):
            result = bench.run_process([sys.executable, '-c', 'raise SystemExit(7)'], dict(os.environ), 2)
        self.assertEqual(result['exitCode'], 7)
        self.assertEqual(result['status'], 'error')
        self.assertTrue(observed and all(observed), 'group signalled after leader was already reaped')

    def test_exited_leader_with_pipe_inheriting_orphan_is_drained_and_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, 'escaped')
            child = 'import time,pathlib; time.sleep(.6); pathlib.Path(' + repr(str(marker)) + ').touch()'
            leader = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); raise SystemExit(7)'
            result = bench.run_process([sys.executable, '-c', leader], dict(os.environ), .25)
            time.sleep(.7)
            self.assertFalse(marker.exists())
        self.assertEqual(result['status'], 'error')
        self.assertEqual(result['exitCode'], 7)
        self.assertLess(result['wallNanoseconds'], 250_000_000)

    def test_discards_stdout_bounds_stderr_and_keeps_valid_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory, 'fake.py')
            script.write_text('import sys\nsys.stdout.write("secret" * 100000)\nsys.stderr.write(' + repr(stderr(trace()).decode()) + ')\nsys.stderr.write("private" * 100000)\n')
            result = bench.run_process([sys.executable, str(script)], dict(os.environ), 2)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['trace'], trace())
        self.assertTrue(result['stderrTruncated'])
        self.assertNotIn('private', json.dumps(result))
        self.assertNotIn('secret', json.dumps(result))

    def test_timeout_kills_owned_descendant_group_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, 'escaped')
            script = Path(directory, 'fake.py')
            script.write_text('import subprocess,sys,time\nsubprocess.Popen([sys.executable,"-c",' +
                              repr('import time,pathlib; time.sleep(0.6); pathlib.Path(' + repr(str(marker)) + ').touch()') + '])\ntime.sleep(30)\n')
            result = bench.run_process([sys.executable, str(script)], dict(os.environ), 0.2)
            self.assertEqual(result['status'], 'timeout')
            time.sleep(0.8)
            self.assertFalse(marker.exists())
        self.assertLess(result['wallNanoseconds'], 2_000_000_000)


FAKE = r'''#!/usr/bin/env python3
import json,os,pathlib,socket,sys,time
args = sys.argv[1:]
with open(os.environ['BENCH_TEST_LOG'], 'a') as log:
    log.write(json.dumps({'pid':os.getpid(), 'args':args, 'name':os.environ.get('SAFARI_BROWSER_NAME'),
        'tmp':os.environ.get('TMPDIR'), 'daemon':os.environ.get('SAFARI_BROWSER_DAEMON'),
        'mcp':os.environ.get('SAFARI_BROWSER_MCP_DIRECT')}) + '\n')
record = {'schemaVersion':1,'requestID':'01234567-89ab-4cde-8fab-0123456789ab','status':'ok',
          'totalNanoseconds':200,'spans':[],'droppedSpans':0}
err = '[safari-browser timing] ' + json.dumps(record) + '\n' if os.environ.get('SAFARI_BROWSER_TRACE_TIMING') == '1' else ''
if args[:2] == ['daemon','__serve']:
    name = args[args.index('--name')+1]
    directory = args[args.index('--socket-dir')+1]
    pathlib.Path(directory, 'safari-browser-'+name+'.sock').touch()
    time.sleep(30)
elif args[:1] == ['mcp']:
    for line in sys.stdin:
        req = json.loads(line)
        if os.environ.get('BENCH_RPC_LOG'):
            with open(os.environ['BENCH_RPC_LOG'], 'a') as f: f.write(req['method'] + '\n')
        if 'id' not in req: continue
        result = {'protocolVersion':'2025-11-25'} if req['method'] == 'initialize' else {
            'isError':False,'structuredContent':{'exit_code':0,'capture_complete':True,'failure':None,
            'stdout':{'encoding':'utf-8','data':'private URL'},'stderr':{'encoding':'utf-8','data':err}}}
        if req['method'] == 'initialize' and os.environ.get('BENCH_RPC_MODE') == 'bad-init': result = []
        if req['method'] == 'tools/call':
            if os.environ.get('BENCH_RPC_MODE') == 'bool': result['structuredContent']['exit_code'] = False
            if os.environ.get('BENCH_RPC_MODE') == 'timeout': time.sleep(3)
        print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
else:
    if args[0] == 'exec':
        steps=json.loads(pathlib.Path(args[args.index('--script')+1]).read_text())
        assert steps == [{'cmd':'wait','args':['0']}] * 3
    sys.stderr.write(err)
'''


class LifecycleTests(unittest.TestCase):
    def test_mcp_eof_does_not_reap_host_before_group_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'fake')
            binary.write_text(FAKE)
            binary.chmod(0o700)
            env = bench.isolated_environment(directory, False)
            env['BENCH_TEST_LOG'] = str(Path(directory, 'log'))
            host = bench.Service(str(binary), env, 'mcp', 2)
            observed = []
            actual_killpg = os.killpg
            def require_owned(pgid, sig):
                try:
                    state = os.waitid(os.P_PID, pgid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                except ChildProcessError:
                    observed.append(False)
                    return
                observed.append(state is not None and state.si_status == 0)
                actual_killpg(pgid, sig)
            with mock.patch.object(bench.os, 'killpg', require_owned):
                host.close()
            self.assertTrue(observed and all(observed), 'MCP EOF reaped host before group cleanup')


    def test_safe_scenarios_namespaces_host_lifetime_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'private-binary')
            binary.write_text(FAKE)
            binary.chmod(0o700)
            log = Path(directory, 'events')
            old = dict(os.environ)
            os.environ.update(BENCH_TEST_LOG=str(log), SAFARI_BROWSER_NAME='user-daemon',
                              SAFARI_BROWSER_DAEMON='1', SAFARI_BROWSER_MCP_DIRECT='1')
            try:
                report = bench.benchmark(str(binary), samples=2, warmups=1, timeout=2, timing='on')
            finally:
                os.environ.clear()
                os.environ.update(old)
            self.assertEqual(len(report['scenarios']), 11)
            regular = [r for r in report['scenarios'] if not r['name'].startswith('live.')]
            self.assertEqual(len(regular), 7)
            self.assertTrue(all(r['statistics']['successful'] == 2 for r in regular), report)
            self.assertTrue(all(r['statistics']['skipped'] == 2 for r in report['scenarios'] if r['name'].startswith('live.')))
            events = [json.loads(line) for line in log.read_text().splitlines()]
            daemons = [e for e in events if e['args'][:2] == ['daemon','__serve']]
            hosts = [e for e in events if e['args'][:1] == ['mcp']]
            self.assertEqual(len(daemons), 4)  # three cold (including warmup), one warm host
            self.assertEqual(len(hosts), 4)
            self.assertEqual(len({e['name'] for e in daemons}), 4)
            status_calls = [e for e in events if e['args'][:2] == ['daemon', 'status']]
            host_names = {e['name']: e['tmp'] for e in daemons}
            self.assertEqual(sorted(sum(e['name'] == name for e in status_calls) for name in host_names), [1, 1, 1, 3])
            for call in status_calls:
                self.assertEqual(call['args'], ['daemon', 'status', '--name', call['name'], '--socket-dir', host_names[call['name']]])
            self.assertTrue(all(e['name'] != 'user-daemon' and e['mcp'] is None for e in events))
            for event in daemons + hosts:
                with self.assertRaises(ProcessLookupError):
                    os.kill(event['pid'], 0)
                self.assertFalse(Path(event['tmp']).exists())
            encoded = json.dumps(report)
            self.assertNotIn(directory, encoded)
            self.assertNotIn('private URL', encoded)
            self.assertEqual(len(report['environment']['binarySHA256']), 64)


class ProtocolFailureTests(unittest.TestCase):
    def test_malformed_initialization_is_reported_without_raw_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'fake')
            binary.write_text(FAKE)
            binary.chmod(0o700)
            old = dict(os.environ)
            os.environ.update(BENCH_TEST_LOG=str(Path(directory, 'log')), BENCH_RPC_MODE='bad-init')
            try:
                try:
                    report = bench.service_scenario(str(binary), 'mcp', False, True, 1, 0, .5)
                except Exception as error:
                    self.fail('Malformed initialization escaped the report boundary: ' + type(error).__name__)
            finally:
                os.environ.clear()
                os.environ.update(old)
            self.assertEqual(report['statistics']['failed'], 1)
            self.assertNotIn(directory, json.dumps(report))

    def test_mcp_malformed_or_timed_out_result_is_not_replayed_or_successful(self):
        for mode in ('bool', 'timeout'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                binary = Path(directory, 'fake')
                binary.write_text(FAKE)
                binary.chmod(0o700)
                events, rpc = Path(directory, 'events'), Path(directory, 'rpc')
                old = dict(os.environ)
                os.environ.update(BENCH_TEST_LOG=str(events), BENCH_RPC_LOG=str(rpc), BENCH_RPC_MODE=mode)
                try:
                    report = bench.service_scenario(str(binary), 'mcp', False, True, 2, 0, .15)
                finally:
                    os.environ.clear()
                    os.environ.update(old)
                self.assertEqual(report['statistics']['successful'], 0)
                self.assertEqual(report['statistics']['failed'], 2)
                self.assertEqual(rpc.read_text().splitlines().count('tools/call'), 1)
                event = json.loads(events.read_text().splitlines()[0])
                with self.assertRaises(ProcessLookupError): os.kill(event['pid'], 0)
                self.assertFalse(Path(event['tmp']).exists())
                self.assertEqual(event['args'], ['mcp', '--timeout', '0.15'])


class LiveTests(unittest.TestCase):
    def test_preflight_requires_explicit_clear_and_no_creation_on_skip(self):
        self.assertTrue(bench.dialog_clear({'status': 'ok'}, b'no blocking dialog found\n'))
        for result, output in [({'status':'error'}, b'no blocking dialog found'),
                ({'status':'ok'}, b''), ({'status':'ok'}, b'blocking dialog present'),
                ({'status':'ok'}, b'no blocking dialog found but incomplete')]:
            self.assertFalse(bench.dialog_clear(result, output))
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'fake')
            binary.write_text(FAKE)
            binary.chmod(0o700)
            log = Path(directory, 'log')
            os.environ['BENCH_TEST_LOG'] = str(log)
            try:
                reports = bench.live_scenarios(str(binary), False, 2, 0, 1)
            finally:
                del os.environ['BENCH_TEST_LOG']
            self.assertEqual([r['statistics']['skipped'] for r in reports], [2, 2, 2, 2])
            self.assertEqual(len(log.read_text().splitlines()), 1)
            self.assertNotIn(directory, json.dumps(reports))

    def live_fixture(self, *, output='correct', ready=True, retained=False, samples=1, timeout=2):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'fake')
            source = FAKE.replace("else:\n    if args[0]", "elif args == ['dialog', 'list']:\n    print('no blocking dialog found')\nelse:\n    if args[0]")
            source = source.replace("    sys.stderr.write(err)", "    if args[0] == 'get':\n        value = 'Benchmark fixture' if args[1] == 'title' else args[-1]\n        mode = os.environ.get('BENCH_GET_OUTPUT', 'correct')\n        print(value if mode == 'correct' else 'private-wrong-output' if mode == 'wrong' else '')\n    sys.stderr.write(err)")
            binary.write_text(source)
            binary.chmod(0o700)
            native = Path(directory, 'native.py')
            native.write_text("import json,os,sys\nwith open(os.environ['BENCH_NATIVE_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\ns=sys.argv[-1]\nif 'make new document' in s: print('42')\nelif 'close w' in s: print('retained' if os.environ.get('BENCH_RETAIN') == '1' else 'closed')\nelif 'return name of tab 1 of w' in s: print('Benchmark fixture' if os.environ.get('BENCH_READY') == '1' else '')\nelse: print('owned')\n")
            events = Path(directory, 'events')
            native_events = Path(directory, 'native-events')
            old = dict(os.environ)
            os.environ.update(BENCH_TEST_LOG=str(events), BENCH_NATIVE_LOG=str(native_events),
                BENCH_RETAIN='1' if retained else '0', BENCH_GET_OUTPUT=output, BENCH_READY='1' if ready else '0')
            actual = bench.run_process
            def redirect(argv, *args, **kwargs):
                if argv[0] == '/usr/bin/osascript':
                    argv = [sys.executable, str(native), *argv[1:]]
                return actual(argv, *args, **kwargs)
            started = time.monotonic()
            try:
                with mock.patch.object(bench, 'run_process', redirect):
                    reports = bench.live_scenarios(str(binary), True, samples, 0, timeout)
            finally:
                os.environ.clear()
                os.environ.update(old)
            elapsed = time.monotonic() - started
            commands = [json.loads(line)['args'] for line in events.read_text().splitlines()]
            native_calls = [json.loads(line)[-1] for line in native_events.read_text().splitlines()]
            self.assertNotIn('127.0.0.1', json.dumps(reports))
            self.assertNotIn('private-wrong-output', json.dumps(reports))
            self.assertNotIn(directory, json.dumps(reports))
            return reports, commands, native_calls, elapsed

    def test_live_fixture_measures_only_exact_target_and_closes_once(self):
        for retained in (False, True):
            with self.subTest(retained=retained):
                reports, commands, native_calls, _ = self.live_fixture(retained=retained, samples=2)
                self.assertEqual([r['statistics']['successful'] for r in reports], [2, 2, 2, 2])
                self.assertTrue(all(r.get('cleanupFailed', False) == retained for r in reports))
                gets = [cmd for cmd in commands if cmd[0] == 'get']
                self.assertEqual(len(gets), 8)
                self.assertTrue(all(cmd[2] == '--url-exact' and cmd[3].startswith('http://127.0.0.1:') for cmd in gets))
                self.assertEqual(sum('make new document' in script for script in native_calls), 1)
                self.assertEqual(sum('close w' in script for script in native_calls), 1)

    def test_live_rejects_wrong_or_empty_output_without_disclosing_it(self):
        for output in ('wrong', 'empty'):
            with self.subTest(output=output):
                reports, _, _, _ = self.live_fixture(output=output)
                self.assertEqual([r['statistics']['successful'] for r in reports], [0, 0, 0, 0])
                self.assertEqual([r['statistics']['failed'] for r in reports], [1, 1, 1, 1])
                self.assertTrue(all(r['samples'][0].get('reason') == 'fixture_output_mismatch' for r in reports))

    def test_live_readiness_times_out_without_recreating_window_or_measuring(self):
        reports, commands, native_calls, elapsed = self.live_fixture(ready=False, timeout=.35)
        self.assertEqual([r['statistics']['failed'] for r in reports], [1, 1, 1, 1])
        self.assertTrue(all(r['samples'][0].get('reason') == 'fixture_readiness_timeout' for r in reports))
        self.assertFalse(any(cmd[0] == 'get' for cmd in commands))
        self.assertEqual(sum('make new document' in script for script in native_calls), 1)
        readiness = [script for script in native_calls if 'return name of tab 1 of w' in script]
        self.assertGreater(len(readiness), 0)
        for script in readiness:
            for guard in ('exists window id 42', 'count tabs of w', 'URL of tab 1 of w', 'count sheets'):
                self.assertIn(guard, script)
                self.assertLess(script.index(guard), script.index('return name of tab 1 of w'))
        self.assertLess(elapsed, 3)

    def test_cleanup_script_requires_id_exact_url_one_tab_and_no_sheets(self):
        url = 'http://127.0.0.1:1234/0123456789abcdef/'
        script = bench.window_script(42, url, close=True)
        for guard in ('exists window id 42', 'count tabs of w', 'URL of tab 1 of w',
                      'count sheets', url):
            self.assertIn(guard, script)
            self.assertLess(script.index(guard), script.index('close w'))
        self.assertEqual(script.count('close w'), 1)
        self.assertNotIn('close w', bench.window_script(42, url))
        for identifier in (True, -1, 0, '42'):
            with self.assertRaises(ValueError):
                bench.window_script(identifier, url, close=True)
        with self.assertRaises(ValueError):
            bench.window_script(42, 'https://user-page.example', close=True)


class CommandLineTests(unittest.TestCase):
    def test_cli_emits_report_for_both_trace_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'fake')
            binary.write_text(FAKE)
            binary.chmod(0o700)
            env = dict(os.environ, BENCH_TEST_LOG=str(Path(directory, 'log')))
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/benchmark-performance.py'),
                '--binary', str(binary), '--samples', '1', '--warmups', '0'], env=env,
                capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(len(report['scenarios']), 22)
            self.assertEqual({r['timing'] for r in report['scenarios']}, {'on', 'off'})
            self.assertTrue(all(s['trace'] is None for r in report['scenarios'] if r['timing'] == 'off' for s in r['samples']))
            self.assertNotIn(directory, result.stdout.decode())

    def test_cli_rejects_zero_samples_and_never_leaks_bad_binary_path(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory, 'secret-binary'))
            for args in (['--binary', path], ['--binary', path, '--samples', '0']):
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/benchmark-performance.py'), *args], capture_output=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(path, (result.stdout + result.stderr).decode())


if __name__ == '__main__':
    unittest.main()
