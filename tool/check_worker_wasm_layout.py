#!/usr/bin/env python3
"""The worker wasm places its shadow stack first in linear memory.

usage: python3 -I tool/check_worker_wasm_layout.py [module.wasm]

With the stack first, `__stack_pointer` starts at the stack size and every
data segment sits above it, so a stack that overflows runs off address 0 and
traps. With the stack last, an overflow writes into the data below it and the
instance goes on with corrupted memory. Checks, on the module's bytes:

- the first global is a mutable i32 (the stack pointer) whose initial value
  is the 2 MiB stack native/worker/build.rs asks for;
- every active data segment starts at or above that value.

Exits 1 with the reason when either fails.
"""

import sys
from pathlib import Path

STACK_BYTES = 2 * 1024 * 1024
DEFAULT = Path(__file__).resolve().parent.parent / 'lib/assets/dart_monty_core_worker.wasm'


def leb(data, i, end, signed=False):
    """A 32-bit LEB128 at i, within data[:end]: (value, next index)."""
    result = shift = 0
    for count in range(5):
        if i >= end:
            raise ValueError('a number runs past the end of its section')
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            if count == 4:  # the fifth byte holds the last four bits
                # Above them: zeros (unsigned) or copies of bit 31 (signed).
                spare = (byte >> 3) & 0xF if signed else byte >> 4
                if spare not in ((0, 0xF) if signed else (0,)):
                    raise ValueError('a number does not fit in 32 bits')
            if signed and byte & 0x40:
                result -= 1 << shift
            return result, i
    raise ValueError('a number is longer than five bytes')


def const_i32(data, i, end):
    """An offset or initial value: exactly `i32.const n; end`."""
    if i >= end or data[i] != 0x41:
        raise ValueError('an initial value is not a single i32.const')
    value, i = leb(data, i + 1, end, signed=True)
    if i >= end or data[i] != 0x0B:
        raise ValueError('an initial value is more than one i32.const')
    return value, i + 1


def layout(data):
    """(initial stack pointer, lowest active data-segment offset or None)."""
    if data[:8] != b'\0asm\x01\0\0\0':
        raise ValueError('not a wasm module')
    stack = lowest = None
    i = 8
    while i < len(data):
        section = data[i]
        size, j = leb(data, i + 1, len(data))
        end = j + size
        if end > len(data):
            raise ValueError('a section runs past the end of the file')
        if section == 6:
            _, j = leb(data, j, end)
            if j + 2 > end or (data[j], data[j + 1]) != (0x7F, 1):
                raise ValueError('the first global is not a mutable i32')
            stack, _ = const_i32(data, j + 2, end)
        elif section == 11:
            count, j = leb(data, j, end)
            for _ in range(count):
                flag, j = leb(data, j, end)
                if flag == 1:  # passive: no offset
                    length, j = leb(data, j, end)
                    j += length
                    if j > end:
                        raise ValueError('a data segment runs past its section')
                    continue
                if flag == 2:  # active, explicit memory index
                    _, j = leb(data, j, end)
                elif flag != 0:
                    raise ValueError(f'unsupported data segment flag {flag}')
                offset, j = const_i32(data, j, end)
                length, j = leb(data, j, end)
                j += length
                if j > end:
                    raise ValueError('a data segment runs past its section')
                lowest = offset if lowest is None else min(lowest, offset)
        i = end
    if stack is None:
        raise ValueError('no global section')
    return stack, lowest


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT
    try:
        stack, lowest = layout(path.read_bytes())
    except (OSError, ValueError, IndexError) as error:
        print(f'FAIL: {path}: {error}')
        return 1
    if stack != STACK_BYTES:
        print(f'FAIL: {path}: initial stack pointer {stack}, expected {STACK_BYTES}: the stack is not first')
        return 1
    if lowest is not None and lowest < stack:
        print(f'FAIL: {path}: a data segment at {lowest} lies inside the stack (below {stack})')
        return 1
    print(f'OK: {path.name}: stack first (0..{stack}), data from {lowest}.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
