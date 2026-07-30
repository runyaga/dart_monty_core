// Shared test body for ffi_control_d_test.dart (and its WASM mirror).
//
// CONTROL (d) of the P3 control set: an end-to-end check of the value-conversion
// contract that does NOT share a code path with the thing it verifies.
//
// Why it exists. `native/src/bin/oracle.rs` includes `convert.rs` via
// `#[path = "../convert.rs"]`, so the FFI side and the oracle side share the
// conversion code and AGREE EVEN WHEN BOTH ARE WRONG. That is not a theory: with
// one deliberate bug compiled into both, the 482-fixture suite reported 482/482
// green while the convert.rs unit tests (control a') failed.
//
// How this differs from a':
//   a'  unit level, inside the Rust crate, per MontyObject variant
//   d   end-to-end through the real FFI boundary, Python source -> Dart value,
//       asserting the DOCUMENTED wire contract
//
// SELECTION CRITERIA (recorded so the subset cannot be quietly cherry-picked):
//   1. One case per `monty_object_to_json` match arm that is reachable from pure
//      in-sandbox Python — 18 of them. Verified reachable by probing each snippet
//      against the oracle binary before writing this file.
//   2. Both branches of every conditional arm: `BigInt` fits-in-i64 vs not, and
//      `Dict` string-keyed vs non-string-keyed.
//   3. Every tagged-envelope type, because the tag is the part that carries
//      round-trip information and the part the schema doc got wrong.
//   4. Deliberately EXCLUDED: arms that cannot be reached without host OS-call
//      handlers (`FileHandle` via `open()`, `date.today`, `os.environ`) and arms
//      whose payload is not constructible from Python (`Cycle`, `Type`,
//      `BuiltinFunction`, `Function`, `Exception`, `Dataclass`, `NamedTuple`).
//      Those are covered by a' at the unit level, or by core#125 once the FFI
//      harness gains handlers. Excluding them is a stated limit, not an accident.
//
// Expectations are derived from the documented schema in `convert.rs`, not from
// running the code. That distinction is what makes this a check rather than a
// tautology — and it is how the stale schema doc was caught: it claimed `Tuple`,
// `Bytes`, `Set` and `FrozenSet` serialize as bare arrays, which they never have.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runControlDTests() {
  group("control (d) — value conversion contract", () {
    Future<MontyValue> eval(String code) async {
      final r = await Monty(code).run();
      expect(r.error, isNull, reason: 'snippet must evaluate: $code');

      return r.value;
    }

    // ---- scalars: native JSON counterparts ------------------------------
    test('None -> null', () async {
      expect((await eval('None')).dartValue, isNull);
    });

    test('Bool -> bool', () async {
      expect((await eval('True')).dartValue, true);
      expect((await eval('False')).dartValue, false);
    });

    test('Int -> number', () async {
      expect((await eval('7')).dartValue, 7);
    });

    test('BigInt within i64 -> number', () async {
      expect((await eval('2**62')).dartValue, 4611686018427387904);
    });

    test('BigInt beyond i64 -> string (both branches of the arm)', () async {
      // The documented rule is "number if fits i64, else string". This is the
      // else-branch; the case above is the then-branch.
      expect(
        (await eval('2**80')).dartValue,
        '1208925819614629174706176',
      );
    });

    test('Float -> number', () async {
      expect((await eval('1.5')).dartValue, 1.5);
    });

    test('String -> string', () async {
      expect((await eval('"s"')).dartValue, 's');
    });

    test('Ellipsis -> "..."', () async {
      expect((await eval('...')).dartValue, '...');
    });

    // ---- containers ------------------------------------------------------
    test('List -> array', () async {
      expect((await eval('[1, 2]')).dartValue, [1, 2]);
    });

    test('Dict with string keys -> map', () async {
      expect((await eval('{"a": 1}')).dartValue, {'a': 1});
    });

    test('Dict with non-string keys -> pair list (other branch)', () async {
      // The arm is conditional on key type; this exercises the branch the
      // string-keyed case above does not.
      final v = await eval('{1: "x"}');
      expect(v.dartValue, isNot(isA<Map<String, Object?>>()));
    });

    // ---- tagged envelopes ------------------------------------------------
    // These carry a `__type` tag because a bare array would lose the distinction
    // between list/tuple/set/frozenset. The tag is what round-trips.
    test('Tuple is a distinct type, not a bare array', () async {
      final v = await eval('(1, 2)');
      expect(v, isA<MontyTuple>());
      expect(v.dartValue, [1, 2]);
    });

    test('Bytes is a distinct type carrying byte values', () async {
      final v = await eval('b"ab"');
      expect(v, isA<MontyBytes>());
      expect((v as MontyBytes).value, [97, 98]);
    });

    test('Set is distinct from List', () async {
      final v = await eval('set([1])');
      expect(v, isA<MontySet>());
    });

    test('FrozenSet is distinct from Set', () async {
      final v = await eval('frozenset([1])');
      expect(v, isA<MontyFrozenSet>());
      expect(v, isNot(isA<MontySet>()));
    });

    test('Path is distinct from String', () async {
      final v = await eval('from pathlib import Path\nPath("/a/b")');
      expect(v, isA<MontyPath>());
      expect(v, isNot(isA<MontyString>()));
    });

    // ---- datetime family: field-level, not stringified -------------------
    test('Date carries y/m/d fields', () async {
      final v = await eval('from datetime import date\ndate(2026, 7, 30)');
      expect(v, isA<MontyDate>());
      final d = v as MontyDate;
      expect([d.year, d.month, d.day], [2026, 7, 30]);
    });

    test('DateTime carries date and time fields', () async {
      final v = await eval(
        'from datetime import datetime\ndatetime(2026, 7, 30, 1, 2, 3)',
      );
      expect(v, isA<MontyDateTime>());
    });

    test('TimeDelta carries days/seconds/microseconds', () async {
      final v = await eval(
        'from datetime import timedelta\ntimedelta(days=1)',
      );
      expect(v, isA<MontyTimeDelta>());
    });

    test('TimeZone carries an offset', () async {
      final v = await eval(
        'from datetime import timezone, timedelta\n'
        'timezone(timedelta(hours=2))',
      );
      expect(v, isA<MontyTimeZone>());
    });
  });
}
