// The type-identity property — invariant I1 of BRIDGE-DESIGN.md.
//
//     montyTypeName(decode(encode(v))) == the contract tag for type(v)
//
// for every `MontyObject` variant WIRE-CONTRACT.md names, on all three
// backends.
//
// This is the instrument the wire work is measured by, and it exists BEFORE
// the wire moves on purpose. Rows the encoder gets wrong today are listed as
// pending with their issue and tier, so the row is exercised and reported
// rather than asserted as correct — pinning current-but-wrong behaviour is what
// made core#129 survive 1062 passing fixtures.
//
// It is a different question from the repr differential, which asks whether a
// value's *contents* survive (I2). This asks whether its *type* is decided by
// the encoder's discriminants and nothing else (I1) — the invariant core#136
// breaks, where sandboxed Python picks the host type by writing a `__type` key.
//
// Verified by mutation: swapping two `__type` strings in convert.rs turns rows
// 14 and 18 red, because a Path then decodes as a Date.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_monty_type_name.dart';

/// True when compiled for the web (dart2js or dart2wasm).
const _isWeb = bool.fromEnvironment('dart.library.js_interop');

/// One row of `WIRE-CONTRACT.md`.
class _Row {
  const _Row(
    this.row,
    this.code,
    this.expected, {
    this.pending,
    this.webPending,
    this.inner = false,
  });

  /// The row number in `WIRE-CONTRACT.md`, so a failure here points at the
  /// contract rather than at a guess about what the right answer is.
  final int row;

  /// Python evaluated through the real pipeline.
  final String code;

  /// The contract tag the decoded value must carry, per the table's `after`
  /// column. Not what it carries today — see [pending].
  final String expected;

  /// Set when today's encoder gets this row wrong on EVERY backend: the issue
  /// and the tier that fixes it. Reported as a skip, never asserted.
  final String? pending;

  /// Set when only the web backends get it wrong (core#128 — the JS bridge
  /// reparses number text). Kept separate from [pending] so a blanket skip
  /// cannot hide that FFI gets these right.
  final String? webPending;

  /// Assert on the first item of the returned list rather than on the list.
  /// Cycles arrive as a container holding the marker, so the marker is what
  /// carries the type.
  final bool inner;
}

/// Every constructible row of the contract table.
///
/// Rows 10 (`NamedTuple`), 19 (`FileHandle`) and 20 (`Dataclass`) are absent,
/// and that is reported as a skip below rather than passed over: `collections`
/// and
/// `dataclasses` are not importable in this build (measured:
/// `ModuleNotFoundError`), and a file handle needs a mounted filesystem. Their
/// Dart types exist and are reached by other paths, so the gap is in THIS
/// instrument, not in the encoder.
const _rows = [
  _Row(1, 'None', 'none'),
  _Row(2, 'True', 'bool'),
  _Row(3, '42', 'int'),
  _Row(
    3,
    '2**53 + 1',
    'int',
    webPending: 'ints above 2^53 lose precision at the JS boundary — core#128',
  ),
  _Row(
    4,
    '2**63',
    'bigint',
    pending: 'ints beyond i64 arrive as MontyString — core#134 (Tier 2)',
  ),
  _Row(
    5,
    '4.0',
    'float',
    webPending: 'integral floats collapse to int at the JS boundary — core#128',
  ),
  _Row(
    5,
    '-0.0',
    'float',
    webPending: 'signed zero is lost at the JS boundary — core#128',
  ),
  _Row(6, '"s"', 'str'),
  _Row(
    6,
    '"NaN"',
    'str',
    pending: 'the string "NaN" decodes as MontyFloat(NaN) — Tier 2',
  ),
  _Row(7, 'b"hi"', 'bytes'),
  _Row(8, '[1, 2]', 'list'),
  _Row(9, '(1, 2)', 'tuple'),
  _Row(11, '{"a": 1}', 'dict'),
  // The forgery. A plain dict naming a host type must stay a dict; today it
  // becomes that type, so untrusted Python chooses its own Dart class.
  _Row(
    11,
    '{"__type": "path", "value": "x"}',
    'dict',
    pending:
        'a plain dict decodes as the tagged type it names — core#136 (Tier 1)',
  ),
  _Row(
    11,
    '{1: "a"}',
    'dict',
    pending: 'non-string-key dicts arrive as MontyList — Tier 2',
  ),
  _Row(12, '{1, 2}', 'set'),
  _Row(13, 'frozenset([1])', 'frozenset'),
  _Row(14, 'import datetime\ndatetime.date(2020, 1, 1)', 'date'),
  _Row(15, 'import datetime\ndatetime.datetime(2020, 1, 1)', 'datetime'),
  _Row(16, 'import datetime\ndatetime.timedelta(days=1)', 'timedelta'),
  _Row(17, 'import datetime\ndatetime.timezone.utc', 'timezone'),
  _Row(18, 'import pathlib\npathlib.Path("x")', 'path'),
  _Row(21, '...', 'ellipsis'),
  _Row(
    22,
    'ValueError("boom")',
    'exception',
    pending:
        'exceptions collapse onto a bare string, byte-identical to the string '
        '"ValueError: boom" — Tier 2',
  ),
  _Row(
    23,
    'int',
    'type',
    pending: 'Type collapses onto a bare string — Tier 2',
  ),
  _Row(
    24,
    '(lambda: 1)',
    'function',
    pending:
        'Function collapses onto a bare string with a fabricated address '
        '— Tier 2',
  ),
  _Row(
    25,
    'abs',
    'builtin',
    pending: 'BuiltinFunction encodes as Rust {:?} ("Abs") — Tier 2',
  ),
  _Row(
    26,
    'class C:\n    pass\nC()',
    'repr',
    pending: 'Repr collapses onto a bare string — Tier 2',
  ),
  _Row(
    27,
    'a = []\na.append(a)\na',
    'cycle',
    pending: 'the cycle marker collapses onto the bare string "[...]" — Tier 2',
    inner: true,
  ),
];

void runWireContractTests() {
  group('wire contract — type identity (I1)', () {
    test('rows 10, 19 and 20 are not covered here', () {
      markTestSkipped(
        'NamedTuple and Dataclass need collections/dataclasses, which this '
        'build does not provide (ModuleNotFoundError), and FileHandle needs a '
        'mounted filesystem. Their Dart types are exercised by '
        'ffi_dataclass_hydrate_test.dart and ffi_open_test.dart instead.',
      );
    });

    for (final r in _rows) {
      test(
        'row ${r.row}: ${r.code.replaceAll('\n', ' ; ')} -> ${r.expected}',
        () async {
          if (r.pending != null) {
            markTestSkipped(r.pending!);

            return;
          }
          if (_isWeb && r.webPending != null) {
            markTestSkipped(r.webPending!);

            return;
          }

          final result = await Monty(r.code).run();
          expect(result.error, isNull, reason: 'evaluating ${r.code} failed');

          var value = result.value;
          if (r.inner) {
            value = (value as MontyList).items.first;
          }

          expect(
            montyTypeName(value),
            r.expected,
            reason:
                'WIRE-CONTRACT.md row ${r.row} requires ${r.expected}; the '
                'pipeline produced ${value.runtimeType}. Either the encoder '
                'tag changed, or the decoder dispatched on something other '
                "than the encoder's discriminant — invariant I1.",
          );
        },
      );
    }
  });
}
