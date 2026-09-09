#!/bin/bash
# Safari-free #130 regression: a cached arithmetic script must not make the
# next delay hang. Both the production daemon and the production CompileCache
# run in disposable child processes with an external wall-clock watchdog.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$TASK_REPO" "${SAFARI_BROWSER_BIN:-$TASK_REPO/.build/debug/safari-browser}" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
binary = Path(sys.argv[2]).resolve()
if not binary.is_file():
    raise SystemExit(f"FAIL: build the binary first: {binary}")

def run_bounded(args, *, timeout, label):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"{label}: exceeded {timeout} s") from error
    assert result.returncode == 0, f"{label}: {result.stdout}\n{result.stderr}"
    return result.stdout

with tempfile.TemporaryDirectory(prefix="sb-executor-") as directory:
    name = "regression"
    socket_path = str(Path(directory, f"safari-browser-{name}.sock"))
    # __serve alone creates no Safari windows and executes no Safari scripts.
    daemon = subprocess.Popen(
        [str(binary), "daemon", "__serve", "--name", name, "--socket-dir", directory],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 3
        while not os.path.exists(socket_path):
            assert daemon.poll() is None, "daemon exited before binding its socket"
            assert time.monotonic() < deadline, "daemon startup exceeded 3 s"
            time.sleep(0.01)

        def request(source, request_id):
            started = time.monotonic()
            # This external client has a deadline even if the Swift executor
            # stops making progress. Closing it never triggers CLI fallback.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(3)
                connection.connect(socket_path)
                reader = connection.makefile("rb")
                handshake = json.loads(reader.readline())
                assert handshake["protocol"]["name"] == "persistent-daemon"
                connection.sendall((json.dumps({
                    "method": "applescript.execute", "params": {"source": source},
                    "requestId": request_id,
                }) + "\n").encode())
                try:
                    response = json.loads(reader.readline())
                except TimeoutError as error:
                    raise AssertionError(f"daemon script {source!r} exceeded 3 s") from error
            assert response["requestId"] == request_id, response
            assert response["result"] == {"status": "ok", "output": "42"}, response
            print(f"PASS daemon request {request_id}: {time.monotonic() - started:.3f} s", flush=True)

        for iteration in range(3):
            request("return 42", iteration * 2 + 1)
            request("delay 0.3\nreturn 42", iteration * 2 + 2)
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=2)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=2)

    # Compile the actual production source with a minimal executable test
    # entry point. No copy of CompileCache and no test-only production API.
    # Keeping this outside XCTest prevents an off-main NSAppleScript deadlock
    # from pinning the entire unit-test process after this regression returns.
    harness = Path(directory, "CacheHarness.swift")
    harness.write_text(r'''
import Foundation

@main struct CacheHarness {
    static func main() async throws {
        let cache = PreCompiledScripts.CompileCache()
        try await Task.detached {
            for _ in 0..<3 {
                for source in ["return 42", "delay 0.3\nreturn 42"] {
                    let result = try await cache.execute(source: source)
                    guard result.stringValue == "42" else {
                        fatalError("unexpected execution result")
                    }
                }
            }
            let count = await cache.cacheCount
            guard count == 2 else { fatalError("cacheCount=\(count), expected 2") }
            print("PASS production CompileCache: 6 executions, cacheCount=2")
        }.value
    }
}
''')
    executable = str(Path(directory, "cache-harness"))
    run_bounded([
        "swiftc", "-swift-version", "6", "-parse-as-library",
        str(repo / "Sources/SafariBrowser/Daemon/PreCompiledScripts.swift"),
        str(harness), "-o", executable,
    ], timeout=30, label="compile cache harness")
    print(run_bounded([executable], timeout=5, label="cached sequence").strip())
PY
