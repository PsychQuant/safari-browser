#!/usr/bin/env python3
"""Run XCTest with evidence of suite completion, not only process exit (#141).

A run that goes silent is stopped, and says which test was running (#343): an async test that waits
on something that never finishes keeps XCTest at 0% CPU for as long as anyone lets it.

Three things that only a real `swift test` shows, each measured:
- On a pipe its output is block-buffered, so the last line read is an old test. It gets a pty, which
  makes it line-buffered.
- `xctest` runs in a process group of its own, so a signal to swift-test's group misses it. SIGINT to
  swift-test is passed on and SIGTERM is not; whatever is left of the process tree is then killed.
- Swift Testing prints `Test name() started.`, not `Test Case 'name' started.`.
"""
import os
import pty
import queue
import re
import signal
import subprocess
import sys
import threading
import time

# Long enough for a quiet link step after a clean build; the whole suite takes about 100 s.
DEFAULT_STALL_SECONDS = 600.0
MAX_STALL_SECONDS = 86400.0
# After the process has exited, how long to wait for output that was still on its way.
DRAIN_SECONDS = 2.0
STOP_PATIENCE_SECONDS = 5.0
POLL_SECONDS = 0.5
# Not anchored: a test's own output can sit in front on the same line.
STARTED = re.compile(r"Test(?: Case)? '?(.+?)'? started\.")
FINISHED = re.compile(r"Test(?: Case)? '?(.+?)'? (?:passed|failed|skipped|recorded an issue)")


def stall_limit():
    raw = os.environ.get('UNIT_TEST_STALL_SECONDS', '')
    if not raw:
        return DEFAULT_STALL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        value = 0
    if not 0 < value <= MAX_STALL_SECONDS:
        print(f'UNIT_TEST_STALL_SECONDS must be a number of seconds above 0 and up to {MAX_STALL_SECONDS:g}, not {raw!r}.',
              file=sys.stderr)
        return None
    return value


def descendants(root):
    listing = subprocess.run(['ps', '-A', '-o', 'pid=,ppid='], capture_output=True, text=True).stdout
    children = {}
    for row in listing.splitlines():
        parts = row.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, waiting = [], [root]
    while waiting:
        for pid in children.get(waiting.pop(), []):
            found.append(pid)
            waiting.append(pid)
    return found


def stop(child):
    """SIGINT first, because swift-test passes that on to the test process; then nothing is left alive."""
    family = descendants(child.pid)
    try:
        os.killpg(child.pid, signal.SIGINT)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        child.wait(timeout=STOP_PATIENCE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    for pid in [child.pid, *family]:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    try:
        child.wait(timeout=STOP_PATIENCE_SECONDS)
    except subprocess.TimeoutExpired:
        pass


def read_lines(descriptor, lines):
    # Undecodable bytes must not end the reader: a dead reader looks like silence.
    with open(descriptor, encoding='utf-8', errors='replace') as stream:
        try:
            for line in stream:
                lines.put(line)
        except OSError:  # a pty's other end closing can read as EIO
            pass
    lines.put(None)


def describe(running, finished):
    if running:
        return 'still running: ' + ', '.join(running)
    if finished:
        return f'nothing was running; the last test to finish was {finished}'
    return 'no test had started (a long build or a wait for SwiftPM\'s lock also looks like this)'


def raise_interrupt(*_):
    raise KeyboardInterrupt


def main():
    limit = stall_limit()
    if limit is None:
        return 2
    signal.signal(signal.SIGTERM, raise_interrupt)
    signal.signal(signal.SIGHUP, raise_interrupt)
    # SwiftPM can propagate an XCTest child's early _exit(0) as success.
    # Require the outer suite summary; a completed individual class is not
    # proof that the remainder of the suite ran. Swift Testing's separate
    # zero-test footer must not mask the XCTest summary.
    reader, writer = pty.openpty()
    child = subprocess.Popen(
        ['swift', 'test', *sys.argv[1:]],
        env=dict(os.environ, SKIP_E2E='1'),
        stdin=subprocess.DEVNULL, stdout=writer, stderr=writer,
        start_new_session=True,
    )
    os.close(writer)
    incoming = queue.Queue()
    threading.Thread(target=read_lines, args=(reader, incoming), daemon=True).start()
    lines = []
    running = []
    finished = None
    closed = False
    heard = time.monotonic()
    try:
        while True:
            try:
                line = incoming.get(timeout=POLL_SECONDS)
            except queue.Empty:
                now = time.monotonic()
                # Something the process left behind can hold the pty open after it has exited.
                if child.poll() is not None and (closed or now - heard >= DRAIN_SECONDS):
                    break
                if now - heard >= limit:
                    stop(child)
                    print(f'FAIL: no output for {limit:g} s: {describe(running, finished)}.', file=sys.stderr)
                    return 1
                continue
            if line is None:
                closed = True
                if child.poll() is not None:
                    break
                continue
            heard = time.monotonic()
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
            started = STARTED.search(line)
            done = FINISHED.search(line)
            if started:
                # Swift Testing also announces the whole run this way.
                if started.group(1) != 'run':
                    running.append(started.group(1))
            elif done:
                if done.group(1) in running:
                    running.remove(done.group(1))
                finished = done.group(1)
        code = child.wait()
    except KeyboardInterrupt:
        stop(child)
        return 130
    if code != 0:
        return code if code > 0 else 1
    summary = re.search(
        r"^Test Suite '(?:All tests|Selected tests)' passed at [^\n]+\n"
        r"\s*Executed ([1-9][0-9]*) tests?, with 0 failures \(0 unexpected\)",
        ''.join(lines), re.MULTILINE,
    )
    if summary is None:
        print('FAIL: XCTest completion summary missing or invalid; exit 0 alone is insufficient.', file=sys.stderr)
        return 1
    print(f'Verified XCTest completion: {summary.group(1)} tests.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
