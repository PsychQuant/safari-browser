#!/usr/bin/env python3
"""Build the guard and runtime's canonical assessment as one Swift unit.

The emitted source is also the mutation gate's input: a moved policy must not
vanish from review simply because it moved out of the CLI wrapper.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group(required=True)
mode.add_argument('--output', type=Path)
mode.add_argument('--emit-source', type=Path)
mode.add_argument('--run', action='store_true')
parser.add_argument('guard_args', nargs=argparse.REMAINDER)
args = parser.parse_args()
if args.guard_args and not args.run:
    parser.error('guard arguments require --run')
root = Path(__file__).resolve().parents[1]
core = root / 'Sources/SafariBrowser/Utilities/SignatureAssessment.swift'
wrapper = root / 'scripts/verify-install-signature.swift'

try:
    cli = wrapper.read_text()
    if cli.startswith('#!'):
        cli = cli.split('\n', 1)[1]
    source = core.read_text() + '\n' + cli
    if args.emit_source:
        args.emit_source.write_text(source)
    else:
        with tempfile.TemporaryDirectory(prefix='signature-guard-build-') as temporary:
            main = Path(temporary) / 'main.swift'
            main.write_text(source)
            output = args.output if args.output else Path(temporary) / 'guard'
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['swiftc', '-O', '-o', str(output), str(main)], check=True)
            if args.run:
                forwarded = args.guard_args[1:] if args.guard_args[:1] == ['--'] else args.guard_args
                result = subprocess.run([str(output), *forwarded])
                sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
except (OSError, subprocess.CalledProcessError) as error:
    print(f'Cannot build signature guard; this is not a signature verdict: {error}', file=sys.stderr)
    sys.exit(70)
