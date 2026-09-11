#!/usr/bin/env python3
"""Compile production storage code; interrupt while a memory snapshot is alive.

Only error/guidance types are stubbed, because this exercises successful reads
and process interruption, not their separately tested diagnostic classification.
No user browser data is read, and no preexisting temp directories are removed.
"""
from pathlib import Path
import plistlib
import selectors
import signal
import sqlite3
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
stubs = '''
enum CodeSigningState { case unknown; static func current() -> Self { .unknown } }
enum SafariBrowserError: Error {
 case safariDataReadFailed(path:String,detail:String)
 case safariDataParseFailed(path:String,detail:String)
 case safariDataFileNotFound(path:String)
 case fullDiskAccessRequired(path:String,signing:CodeSigningState)
}
'''
main = '''
let source = URL(fileURLWithPath: CommandLine.arguments[2])
func hold() -> Never {
    print("READY")
    fflush(stdout)
    while true { Thread.sleep(forTimeInterval: 1) }
}
if CommandLine.arguments[1] == "sqlite" {
    try SafariDataStore.withDatabaseSnapshot(sourceURL: source) { db in
        let filenames = try SQLiteReader.query(in: db, sql: "PRAGMA database_list") { $0[2].stringValue }
        precondition(filenames == [""])
        withExtendedLifetime(db) { hold() }
    }
} else {
    let bytes = try SafariDataStore.readPlist(sourceURL: source)
    precondition(!bytes.isEmpty)
    withExtendedLifetime(bytes) { hold() }
}
'''
with tempfile.TemporaryDirectory(prefix='snapshot-interruption-') as folder:
    work = Path(folder)
    source = work / 'main.swift'
    source.write_text(stubs + '\n' + '\n'.join((root / f'Sources/SafariBrowser/Utilities/{name}.swift').read_text() for name in ['SafariDataStore', 'SQLiteReader']) + '\n' + main)
    binary = work / 'snapshot-probe'
    subprocess.run(['swiftc', '-o', str(binary), str(source)], check=True)
    database = work / 'fixture.db'
    connection = sqlite3.connect(database)
    connection.execute('PRAGMA journal_mode=WAL')
    connection.execute('CREATE TABLE t(x)')
    connection.executemany('INSERT INTO t VALUES(?)', [(x,) for x in range(1000)])
    connection.commit()
    plist = work / 'fixture.plist'
    plist.write_bytes(plistlib.dumps({'DownloadHistory': []}))
    temporary = Path(tempfile.gettempdir())
    for mode, file in [('sqlite', database), ('plist', plist)]:
        for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGKILL]:
            before = set(temporary.glob('safari-data-*'))
            child = subprocess.Popen([str(binary), mode, str(file)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    assert selector.select(timeout=10), 'snapshot did not become ready'
                    assert child.stdout.readline().strip() == 'READY', child.stderr.read()
                child.send_signal(sig)
                child.wait(timeout=5)
                assert child.returncode == -sig, (mode, sig, child.returncode)
                assert set(temporary.glob('safari-data-*')) == before, 'new disk copy survived interruption'
                print(f'PASS {mode} {sig.name}: memory ready, terminated, no disk copy', flush=True)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
    connection.close()
