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
    // ignore: unused_element_parameter — see the field doc; the mechanism stays
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
  ///
  /// **Currently unused, and deliberately kept.** Every row that had one is
  /// fixed by Tiers 1 and 2. The field stays because the mechanism is the
  /// point: a newly-found defect gets a `pending` row with its issue, never a
  /// green test asserting the wrong answer.
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
/// Rows 10, 19, 20 and 24 are absent, and that is reported as a skip below
/// rather than passed over — in every case the gap is in THIS instrument, not
/// in the encoder:
///
/// - 10 `NamedTuple` / 20 `Dataclass` — `collections` and `dataclasses` are not
///   importable in this build (measured: `ModuleNotFoundError`).
/// - 19 `FileHandle` — needs a mounted filesystem.
/// - 24 `Function` — **not reachable from Python at all** on monty v0.0.19.
///   Measured: a lambda, a `def` function and a class all come back as
///   `Repr` (`<function 'f' at 0xc>`), never `Function`. Row 24 was briefly
///   asserted against `(lambda: 1)` here and failed with
///   `Expected: 'function' Actual: 'repr'`, which is how this was found.
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
  // core#134 CLOSED by Tier 2: a value's type no longer depends on its
  // magnitude.
  _Row(4, '2**63', 'bigint'),
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
  // The STRING "NaN" is a string. It used to decode as MontyFloat(NaN) because
  // non-finite floats travelled as bare text.
  _Row(6, '"NaN"', 'str'),
  // ...and the non-finite floats themselves still arrive as floats.
  _Row(5, 'float("nan")', 'float'),
  _Row(5, 'float("inf")', 'float'),
  _Row(7, 'b"hi"', 'bytes'),
  _Row(8, '[1, 2]', 'list'),
  _Row(9, '(1, 2)', 'tuple'),
  _Row(11, '{"a": 1}', 'dict'),
  // THE FORGERY, now asserted rather than pending — core#136 CLOSED by Tier 1.
  // A dict whose keys spell a type envelope is a dict. It used to arrive as a
  // genuine MontyPath, letting sandboxed Python choose its own host class.
  _Row(11, '{"__type": "path", "value": "x"}', 'dict'),
  // Non-string keys: was a bare array decoding as MontyList (a dict silently
  // becoming a sequence). Now the `entries` envelope, decoding as
  // MontyPairsDict — which carries the same wire tag, so the same row.
  _Row(11, '{1: "a"}', 'dict'),
  _Row(12, '{1, 2}', 'set'),
  _Row(13, 'frozenset([1])', 'frozenset'),
  _Row(14, 'import datetime\ndatetime.date(2020, 1, 1)', 'date'),
  _Row(15, 'import datetime\ndatetime.datetime(2020, 1, 1)', 'datetime'),
  _Row(16, 'import datetime\ndatetime.timedelta(days=1)', 'timedelta'),
  _Row(17, 'import datetime\ndatetime.timezone.utc', 'timezone'),
  _Row(18, 'import pathlib\npathlib.Path("x")', 'path'),
  _Row(21, '...', 'ellipsis'),
  _Row(22, 'ValueError("boom")', 'exception'),
  _Row(23, 'int', 'type'),
  _Row(25, 'abs', 'builtin'),
  _Row(26, 'class C:\n    pass\nC()', 'repr'),
  _Row(27, 'a = []\na.append(a)\na', 'cycle', inner: true),
];

void runWireContractTests() {
  group('wire contract — type identity (I1)', () {
    test('rows 10, 19, 20 and 24 are not covered here', () {
      markTestSkipped(
        'NamedTuple and Dataclass need collections/dataclasses, which this '
        'build does not provide (ModuleNotFoundError); FileHandle needs a '
        'mounted filesystem; and Function is not reachable from Python on '
        'monty v0.0.19 — lambdas, def functions and classes all arrive as '
        'Repr. Covered elsewhere: ffi_dataclass_hydrate_test.dart, '
        'ffi_open_test.dart, and the Function encoder arm by a Rust unit test.',
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
            // Destructured rather than indexed, which asserts the shape instead
            // of reaching into it: a cycle arrives as a ONE-item container
            // holding the marker, and if that stops being true this row would
            // otherwise silently measure a different value. It also satisfies
            // two DCM rules that contradict each other on the alternatives —
            // prefer-first wants `.first` where avoid-unsafe-collection-methods
            // forbids it, and both reject `[0]`.
            if (value case MontyList(items: [final marker])) {
              value = marker;
            } else {
              fail(
                'row ${r.row} expects a one-item container holding the marker, '
                'got $value',
              );
            }
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
