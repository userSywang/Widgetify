"""Version-bound local binary changes for Widgetify 4.55 (216), arm64."""
import hashlib
import json
import struct
from pathlib import Path

SUPPORTED_SHA256 = '1d4ba54b569dd438067da190a18ce6eff9a8a5f71599f4c6d7248fbfee6948e0'

def arm64_slice(data):
    magic, count = struct.unpack_from('>II', data)
    if magic != 0xcafebabe:
        raise ValueError('Expected a universal Mach-O executable')
    for i in range(count):
        cpu, _, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + i * 20)
        if cpu == 0x100000c:
            return offset, size
    raise ValueError('arm64 slice is missing')

def patch(executable):
    executable = Path(executable)
    data = bytearray(executable.read_bytes())
    if hashlib.sha256(data).hexdigest() != SUPPORTED_SHA256:
        raise ValueError('Unsupported base executable. Use the original Widgetify 4.55 (216), not a previously modified copy.')
    arm, _ = arm64_slice(data)
    changes = []
    def branch(source, target):
        return 0x14000000 | (((target-source)//4) & 0x3ffffff)
    def write(address, words):
        offset = arm + address - 0x100000000
        replacement = b''.join(struct.pack('<I', word) for word in words)
        changes.append({'address': hex(address), 'before': data[offset:offset+len(replacement)].hex(), 'after': replacement.hex()})
        data[offset:offset+len(replacement)] = replacement
    original_store = struct.unpack_from('<I', data, arm + 0x1530a8)[0]
    assert original_store == 0x381303bf
    write(0x100146400, [0x52800020, 0xd65f03c0, 0x52800029, (original_store & ~31) | 9, branch(0x100146410, 0x1001530ac)])
    write(0x1001530a8, [branch(0x1001530a8, 0x100146408)])
    write(0x100149950, [0x52800039])
    write(0x100156664, [0x52800035])
    executable.write_bytes(data)
    return changes
