"""tool/check_worker_wasm_layout.py on small hand-built modules.

Run: python3 -I test/tool/wasm_layout_test.py
Each module has one mutable i32 global and one active data segment, so the
checker's verdict depends only on where the stack pointer and the data sit.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('layout', ROOT / 'tool/check_worker_wasm_layout.py')
layout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(layout)

STACK = 2 * 1024 * 1024


def sleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        done = (value == 0 and not byte & 0x40) or (value == -1 and byte & 0x40)
        out.append(byte if done else byte | 0x80)
        if done:
            return bytes(out)


def uleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | 0x80 if value else byte)
        if not value:
            return bytes(out)


def section(sid, body):
    return bytes([sid]) + uleb(len(body)) + body


def module(sp=STACK, offset=STACK, flag=0, offset_expr=None, payload=b'abc'):
    glob = section(6, uleb(1) + bytes([0x7F, 1, 0x41]) + sleb(sp) + bytes([0x0B]))
    expr = offset_expr if offset_expr is not None else bytes([0x41]) + sleb(offset) + bytes([0x0B])
    head = uleb(flag) + (uleb(0) if flag == 2 else b'')
    data = section(11, uleb(1) + head + expr + uleb(len(payload)) + payload)
    return b'\0asm\x01\0\0\0' + glob + data


class LayoutTest(unittest.TestCase):
    def test_stack_first_is_accepted(self):
        self.assertEqual(layout.layout(module()), (STACK, STACK))

    def test_explicit_memory_index_is_the_same_module(self):
        self.assertEqual(layout.layout(module(flag=2)), (STACK, STACK))

    def test_data_inside_the_stack_is_found(self):
        self.assertEqual(layout.layout(module(offset=1024)), (STACK, 1024))

    def test_an_offset_expression_beyond_one_constant_is_refused(self):
        expr = bytes([0x41]) + sleb(STACK) + bytes([0x41, 1, 0x6B, 0x0B])  # STACK - 1
        with self.assertRaises(ValueError):
            layout.layout(module(offset_expr=expr))

    def test_a_truncated_module_is_refused(self):
        with self.assertRaises(ValueError):
            layout.layout(module()[:-1])

    def test_an_overlong_number_is_refused(self):
        with self.assertRaises(ValueError):
            layout.leb(bytes([0x80] * 5 + [0x00]), 0, 6)

    def test_a_passive_segment_past_its_section_is_refused(self):
        glob = section(6, uleb(1) + bytes([0x7F, 1, 0x41]) + sleb(STACK) + bytes([0x0B]))
        data = section(11, uleb(1) + uleb(1) + uleb(100))
        with self.assertRaises(ValueError):
            layout.layout(b'\0asm\x01\0\0\0' + glob + data)

    def test_a_five_byte_number_must_fit_32_bits(self):
        with self.assertRaises(ValueError):
            layout.leb(bytes([0x80, 0x80, 0x80, 0x80, 0x08]), 0, 5, signed=True)
        self.assertEqual(layout.leb(bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x07]), 0, 5, signed=True)[0], 2**31 - 1)
        self.assertEqual(layout.leb(bytes([0x80, 0x80, 0x80, 0x80, 0x78]), 0, 5, signed=True)[0], -(2**31))
        with self.assertRaises(ValueError):
            layout.leb(bytes([0x80, 0x80, 0x80, 0x80, 0x10]), 0, 5)

    def test_main_verdicts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            good, last = Path(tmp) / 'good.wasm', Path(tmp) / 'last.wasm'
            good.write_bytes(module())
            last.write_bytes(module(sp=4 * STACK, offset=1024))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(layout.main(['x', str(good)]), 0)
                self.assertEqual(layout.main(['x', str(last)]), 1)


if __name__ == '__main__':
    unittest.main()
