#!/usr/bin/env python3
"""Flip one sealed instruction byte in a selected slice of our test fixture.

Only handles the big-endian FAT_MAGIC + little-endian MH_MAGIC_64 format
emitted by this suite's clang/lipo command. Other shapes fail loudly.
"""
from pathlib import Path
import struct
import sys

path, architecture = sys.argv[1:]
cpu = {'arm64': 0x100000C, 'x86_64': 0x1000007}[architecture]
p = Path(path)
b = bytearray(p.read_bytes())
magic, count = struct.unpack_from('>II', b)
assert magic == 0xCAFEBABE and count == 2, 'expected two-slice universal fixture'
slices = [struct.unpack_from('>IIIII', b, 8 + i * 20) for i in range(count)]
assert {item[0] for item in slices} == {0x100000C, 0x1000007}
_, _, base, size, _ = next(item for item in slices if item[0] == cpu)
assert base + size <= len(b)
header = struct.unpack_from('<IIIIIIII', b, base)
assert header[0] == 0xFEEDFACF and header[1] == cpu
position = base + 32
for _ in range(header[4]):
    command, length = struct.unpack_from('<II', b, position)
    assert length >= 8 and position + length <= base + size
    if command == 0x19:  # LC_SEGMENT_64
        sections = struct.unpack_from('<I', b, position + 64)[0]
        assert 72 + sections * 80 <= length
        for i in range(sections):
            section = position + 72 + i * 80
            if bytes(b[section:section+16]).rstrip(b'\0') == b'__text':
                text_size = struct.unpack_from('<Q', b, section + 40)[0]
                offset = struct.unpack_from('<I', b, section + 48)[0]
                assert text_size > 0 and offset + text_size <= size
                b[base + offset] ^= 0xFF
                p.write_bytes(b)
                raise SystemExit(0)
    position += length
raise SystemExit('fixture has no __text section')
