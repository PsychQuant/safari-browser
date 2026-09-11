#!/usr/bin/env python3
"""Compile the guard and runtime's canonical assessment as one Swift unit.

The emitted source is also the mutation gate's input: a moved policy must not
vanish from review simply because it moved out of the CLI wrapper.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group(required=True)
mode.add_argument('--output', type=Path)
mode.add_argument('--emit-source', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
core = root / 'Sources/SafariBrowser/Utilities/SignatureAssessment.swift'
wrapper = root / 'scripts/verify-install-signature.swift'
cli = wrapper.read_text()
if cli.startswith('#!'):
    cli = cli.split('\n', 1)[1]
source = core.read_text() + '\n' + cli
if args.emit_source:
    args.emit_source.write_text(source)
else:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='signature-guard-build-') as temporary:
        main = Path(temporary) / 'main.swift'
        main.write_text(source)
        subprocess.run(['swiftc', '-O', '-o', str(args.output), str(main)], check=True)
