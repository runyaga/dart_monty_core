// Unit tests for the MontyValue subtypes — equality, hashCode, the internal
// tagged projection (toJson) and the dartValue projection.
//
// Pure value-level tests: no interpreter, no FFI, no WASM. Catches
// regressions in deep-equality and projection shape drift without needing
// the integration harness to fire.
@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:test/test.dart';

void main() {
  // ------------------------------------------------------------------
  // Scalars
  // ------------------------------------------------------------------

  group('MontyNone', () {
    test('all instances compare equal and share a hashCode', () {
      const a = MontyNone();
      const b = MontyNone();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('toJson is null', () {
      const a = MontyNone();
      expect(a.toJson(), isNull);
    });

    test('dartValue is null', () {
      expect(const MontyNone().dartValue, isNull);
    });

    test('toString contains type name', () {
      expect(const MontyNone().toString(), 'MontyNone()');
    });
  });

  group('MontyBool', () {
    test('equality + hashCode agree on value', () {
      const a = MontyBool(true);
      const b = MontyBool(true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyBool(false)));
    });

    test("is a number, as Python's bool is an int", () {
      expect(const MontyBool(true), const MontyInt(1));
      expect(const MontyBool(true).hashCode, const MontyInt(1).hashCode);
      expect(const MontyBool(false), const MontyFloat(0));
      expect(const MontyBool(true), isNot(const MontyInt(2)));
      expect(const MontyBool(true), isNot(const MontyString('True')));
    });

    test('toJson + dartValue', () {
      expect(const MontyBool(true).toJson(), true);
      expect(const MontyBool(false).dartValue, false);
    });
  });

  group('MontyInt', () {
    test('equality + hashCode', () {
      const a = MontyInt(42);
      const b = MontyInt(42);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyInt(43)));
      expect(const MontyInt(0), const MontyBool(false));
      expect(const MontyInt(0), isNot(const MontyString('0')));
    });

    test('toJson + dartValue within the exact range', () {
      expect(const MontyInt(42).toJson(), 42);
      expect(const MontyInt(-7).dartValue, -7);
      // 2^53 exactly is the last value every backend holds in a Dart `int`.
    });

    // The past-2^53 cases live in monty_value_int64_vm_test.dart. They cannot
    // be here: an `int` beyond 2^53 is unrepresentable on dart2js, and
    // `0x7FFFFFFFFFFFFFFF` is a dart2js COMPILE error — which would take this
    // whole file down with it, and a `skip:` cannot help because the failure
    // happens before any test runs.
  });

  group('MontyFloat', () {
    test('regular value equality + hashCode', () {
      const a = MontyFloat(3.14);
      const b = MontyFloat(3.14);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyFloat(2.71)));
    });

    test('NaN equals NaN (Python semantics, divergent from Dart double)', () {
      const a = MontyFloat(double.nan);
      const b = MontyFloat(double.nan);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('infinities and their negatives compare correctly', () {
      expect(
        const MontyFloat(double.infinity),
        const MontyFloat(double.infinity),
      );
      expect(
        const MontyFloat(double.negativeInfinity),
        const MontyFloat(double.negativeInfinity),
      );
      expect(
        const MontyFloat(double.infinity),
        isNot(const MontyFloat(double.negativeInfinity)),
      );
    });

    test('toJson encodes the non-finite forms as tagged envelopes', () {
      expect(const MontyFloat(double.nan).toJson(), {
        '__type': 'float',
        'value': 'NaN',
      });
      expect(const MontyFloat(double.infinity).toJson(), {
        '__type': 'float',
        'value': 'Infinity',
      });
      // Wire v3: the non-finite forms are TAGGED. They used to be bare strings,
      // which is why the str "NaN" decoded as a float.
      expect(const MontyFloat(double.negativeInfinity).toJson(), {
        '__type': 'float',
        'value': '-Infinity',
      });
      // A finite float is still a plain JSON number.
      expect(const MontyFloat(3.14).toJson(), 3.14);
    });
  });

  group('MontyString', () {
    test('equality + hashCode', () {
      const a = MontyString('hi');
      const b = MontyString('hi');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyString('bye')));
    });

    test('toJson + dartValue', () {
      expect(const MontyString('hello').toJson(), 'hello');
      expect(const MontyString('').dartValue, '');
    });

    test('the string "NaN" projects as a bare STRING', () {
      // Was: 'special-float strings are NOT mistaken for strings on
      // round-trip', asserting isA<MontyFloat>() and calling the collision "the
      // intended escape encoding" while documenting it as a limit. It was a
      // defect: `float('nan')` and the str `"NaN"` had one wire representation,
      // so the decoder had to guess and guessed wrong half the time. Non-finite
      // floats now carry a `float` envelope, and a bare string is a `str`.
      for (final text in ['NaN', 'Infinity', '-Infinity']) {
        expect(
          MontyString(text).toJson(),
          text,
          reason: 'the STRING "$text" must project as a string',
        );
      }
    });
  });

  // ------------------------------------------------------------------
  // Collections
  // ------------------------------------------------------------------

  group('MontyBytes', () {
    test('deep equality on byte list', () {
      const a = MontyBytes([1, 2, 3]);
      const b = MontyBytes([1, 2, 3]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyBytes([1, 2, 4])));
    });

    test('dartValue exposes the byte list', () {
      expect(const MontyBytes([1, 2, 3]).dartValue, [1, 2, 3]);
    });
  });

  group('MontyList', () {
    test('deep equality across nested values', () {
      const a = MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]);
      const b = MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different element order is not equal', () {
      expect(
        const MontyList([MontyInt(1), MontyInt(2)]),
        isNot(const MontyList([MontyInt(2), MontyInt(1)])),
      );
    });

    test('toJson recursively serialises elements', () {
      expect(
        const MontyList([MontyInt(1), MontyString('x')]).toJson(),
        [1, 'x'],
      );
    });

    test('dartValue recursively projects', () {
      expect(
        const MontyList([MontyInt(1), MontyString('x')]).dartValue,
        [1, 'x'],
      );
    });
  });

  group('MontyTuple', () {
    test('equality + hashCode', () {
      const a = MontyTuple([MontyInt(1), MontyString('x')]);
      const b = MontyTuple([MontyInt(1), MontyString('x')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('not equal to a MontyList with the same elements', () {
      const t = MontyTuple([MontyInt(1)]);
      const l = MontyList([MontyInt(1)]);
      expect(t, isNot(l));
    });

    test('toJson includes __type discriminator', () {
      expect(
        const MontyTuple([MontyInt(1)]).toJson(),
        {
          '__type': 'tuple',
          'value': [1],
        },
      );
    });
  });

  group('MontyDict', () {
    test('equality + hashCode (deep)', () {
      const a = MontyDict([(MontyString('k'), MontyInt(1))]);
      const b = MontyDict([(MontyString('k'), MontyInt(1))]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('order-independent equality, any key type', () {
      // Order-insensitive, matching the sandbox, which answers True for both
      // shapes. This used to hold ONLY for string keys: a non-string-keyed
      // dict was a separate class comparing as a List, so the same Python dict
      // compared UNEQUAL purely because its keys were not strings.
      const a = MontyDict([
        (MontyString('a'), MontyInt(1)),
        (MontyString('b'), MontyInt(2)),
      ]);
      const b = MontyDict([
        (MontyString('b'), MontyInt(2)),
        (MontyString('a'), MontyInt(1)),
      ]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      const c = MontyDict([
        (MontyInt(1), MontyString('a')),
        (MontyInt(2), MontyString('b')),
      ]);
      const d = MontyDict([
        (MontyInt(2), MontyString('b')),
        (MontyInt(1), MontyString('a')),
      ]);
      expect(c, d);
      expect(c.hashCode, d.hashCode);
    });

    test('unequal when a value differs', () {
      const a = MontyDict([(MontyString('k'), MontyInt(1))]);
      const b = MontyDict([(MontyString('k'), MontyInt(2))]);
      expect(a, isNot(b));
    });

    test('toJson: compact shape for all-string keys', () {
      // Was: 'preserves the entry shape (no __type)', asserting {'k': 1}.
      // That shape IS core#136 — a bare object was byte-identical to a type
      // envelope, so a dict could name a host type.
      expect(
        const MontyDict([
          (MontyString('k'), MontyInt(1)),
          (MontyString('s'), MontyString('x')),
        ]).toJson(),
        {
          '__type': 'dict',
          'value': {'k': 1, 's': 'x'},
        },
      );
    });

    test('toJson: entries shape for non-string keys', () {
      expect(const MontyDict([(MontyInt(1), MontyString('a'))]).toJson(), {
        '__type': 'dict',
        'entries': [
          [1, 'a'],
        ],
      });
    });

    test('dartValue is a Map for string keys, pairs otherwise', () {
      // Conditional on key type by design -- see the dartValue doc comment.
      expect(
        const MontyDict([
          (MontyString('a'), MontyInt(1)),
          (MontyString('b'), MontyString('x')),
        ]).dartValue,
        {'a': 1, 'b': 'x'},
      );
      expect(
        const MontyDict([(MontyInt(1), MontyString('x'))]).dartValue,
        [
          [1, 'x'],
        ],
      );
    });
  });

  group('MontySet', () {
    test(
      // TITLE CORRECTED. It read 'treated as ordered list under deep equality',
      // which 17b175f made the OPPOSITE of the truth: MontySet compares
      // order-INSENSITIVELY now, matching the sandbox. The body never
      // exercised order either way -- both operands are in the same order --
      // so nothing failed when the implementation was inverted underneath it.
      // The order property itself lives in monty_set_order_equality_test.dart.
      'equal sets with identical contents compare and hash equally',
      () {
        const a = MontySet([MontyInt(1), MontyInt(2)]);
        const b = MontySet([MontyInt(1), MontyInt(2)]);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      },
    );

    test('toJson includes __type', () {
      expect(
        const MontySet([MontyInt(1)]).toJson(),
        {
          '__type': 'set',
          'value': [1],
        },
      );
    });

    test('equal to a MontyFrozenSet with the same items', () {
      const s = MontySet([MontyInt(1)]);
      const fs = MontyFrozenSet([MontyInt(1)]);
      expect(s, fs);
      expect(fs, s);
      expect(s.hashCode, fs.hashCode);
      expect(s, isNot(const MontyFrozenSet([MontyInt(2)])));
    });
  });

  group('MontyFrozenSet', () {
    test('equality + hashCode', () {
      const a = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      const b = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  // ------------------------------------------------------------------
  // DateTime types
  // ------------------------------------------------------------------

  group('MontyDate', () {
    test('equality + hashCode', () {
      const a = MontyDate(year: 2026, month: 4, day: 28);
      const b = MontyDate(year: 2026, month: 4, day: 28);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different field is not equal', () {
      expect(
        const MontyDate(year: 2026, month: 4, day: 28),
        isNot(const MontyDate(year: 2026, month: 4, day: 27)),
      );
    });

    test('dartValue is a Dart DateTime at midnight', () {
      const d = MontyDate(year: 2026, month: 4, day: 28);
      expect(d.dartValue, DateTime(2026, 4, 28));
    });

    test('toString pads month and day', () {
      expect(
        const MontyDate(year: 2026, month: 1, day: 5).toString(),
        'MontyDate(2026-01-05)',
      );
    });
  });

  group('MontyDateTime', () {
    test('equality + hashCode (naive)', () {
      const a = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      const b = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('tz-aware: offsetSeconds + name participate in equality', () {
      const naive = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
      );
      const aware = MontyDateTime(
        year: 2026,
        month: 4,
        day: 28,
        hour: 15,
        minute: 30,
        second: 45,
        offsetSeconds: 0,
        timezoneName: 'UTC',
      );
      expect(naive, isNot(aware));
    });
  });

  group('MontyTimeDelta', () {
    test('equality + hashCode', () {
      const a = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      const b = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('dartValue is a Duration', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 3600).dartValue,
        const Duration(days: 1, seconds: 3600),
      );
    });
  });

  group('MontyTimeZone', () {
    test('equality + hashCode (named)', () {
      const a = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      const b = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different offsets are not equal', () {
      expect(
        const MontyTimeZone(offsetSeconds: 0, name: 'UTC'),
        isNot(const MontyTimeZone(offsetSeconds: 3600, name: 'UTC')),
      );
    });
  });

  // ------------------------------------------------------------------
  // Structured types
  // ------------------------------------------------------------------

  group('MontyPath', () {
    test('equality + hashCode', () {
      final a = MontyPath('/data/hello.txt');
      final b = MontyPath('/data/hello.txt');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('dartValue is the path string', () {
      expect(MontyPath('/etc').dartValue, '/etc');
    });

    test('different paths are not equal', () {
      expect(MontyPath('/a'), isNot(MontyPath('/b')));
    });
  });

  group('MontyNamedTuple', () {
    test('equality + hashCode (typeName + fields + values)', () {
      const a = MontyNamedTuple(
        typeName: 'sys.version_info',
        fieldNames: ['major', 'minor', 'micro'],
        values: [MontyInt(3), MontyInt(14), MontyInt(0)],
      );
      const b = MontyNamedTuple(
        typeName: 'sys.version_info',
        fieldNames: ['major', 'minor', 'micro'],
        values: [MontyInt(3), MontyInt(14), MontyInt(0)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different names are equal, as Python compares a tuple', () {
      const a = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      const b = MontyNamedTuple(
        typeName: 'Vec',
        fieldNames: ['u', 'v'],
        values: [MontyInt(1), MontyInt(2)],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, const MontyTuple([MontyInt(1), MontyInt(2)]));
      expect(a.hashCode, const MontyTuple([MontyInt(1), MontyInt(2)]).hashCode);
    });

    test('different field values are not equal', () {
      const a = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      const b = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(3)],
      );
      expect(a, isNot(b));
    });

    test('dartValue exposes the toJson map', () {
      const nt = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(nt.dartValue, nt.toJson());
    });
  });

  // ------------------------------------------------------------------
  // MontyValue.fromDart
  // ------------------------------------------------------------------

  group('MontyValue.fromDart', () {
    test('passes MontyValue instances through', () {
      const v = MontyInt(42);
      expect(MontyValue.fromDart(v), same(v));
    });

    test('null / bool / int / double / String → matching scalar', () {
      expect(MontyValue.fromDart(null), const MontyNone());
      expect(MontyValue.fromDart(true), const MontyBool(true));
      expect(MontyValue.fromDart(42), const MontyInt(42));
      expect(MontyValue.fromDart(3.14), const MontyFloat(3.14));
      expect(MontyValue.fromDart('hi'), const MontyString('hi'));
    });

    test('Dart DateTime → MontyDateTime in UTC', () {
      final dt = DateTime.utc(2026, 4, 28, 15, 30, 45, 0, 123);
      final got = MontyValue.fromDart(dt);
      expect(got, isA<MontyDateTime>());
      final mdt = got as MontyDateTime;
      expect(mdt.year, 2026);
      expect(mdt.month, 4);
      expect(mdt.day, 28);
      expect(mdt.hour, 15);
      expect(mdt.minute, 30);
      expect(mdt.second, 45);
      expect(mdt.microsecond, 123);
    });

    test('a Uint8List becomes MontyBytes, not a list of ints', () {
      final got = MontyValue.fromDart(Uint8List.fromList([0, 1, 255]));
      expect(got, isA<MontyBytes>());
      expect((got as MontyBytes).value, [0, 1, 255]);
    });

    // The tagged map a wrapper's dartValue returns is transport shape. Fed
    // back it would reach the sandbox as a plain dict carrying the tag keys,
    // so it is refused and the typed value is passed instead.
    for (final (name, MontyValue value) in [
      (
        'MontyNamedTuple',
        const MontyNamedTuple(
          typeName: 'N',
          fieldNames: ['a'],
          values: [MontyInt(1)],
        ),
      ),
      ('MontyTimeZone', const MontyTimeZone(offsetSeconds: 7200, name: 'X')),
      ('MontyComplex', const MontyComplex(1, 2)),
      ('MontyFileHandle', MontyFileHandle('/f', 'r')),
      ('MontyExceptionValue', MontyExceptionValue('ValueError', 'bad')),
    ]) {
      test('the dartValue map of $name is refused', () {
        final map = value.dartValue;
        expect(map, isA<Map<String, Object?>>());
        expect(
          () => MontyValue.fromDart(map),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('pass the MontyValue'),
            ),
          ),
        );
        expect(MontyValue.fromDart(value), same(value));
      });
    }

    test('a plain dict with a __type key of its own is still a dict', () {
      final got = MontyValue.fromDart({'__type': 'mine', 'x': 1});
      expect(got, isA<MontyDict>());
    });

    test('Dart List → MontyList with recursive conversion', () {
      final got = MontyValue.fromDart([1, 'x', true]);
      expect(
        got,
        const MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]),
      );
    });

    test('Dart Map → MontyDict, keys and values both converted', () {
      final got = MontyValue.fromDart({'k': 1, 'n': null});
      expect(
        got,
        const MontyDict([
          (MontyString('k'), MontyInt(1)),
          (MontyString('n'), MontyNone()),
        ]),
      );
    });

    test('Map with non-String keys keeps the key TYPE', () {
      // INVERTED. This used to assert the keys came back as the STRINGS '1'
      // and '2', because fromDart forced every key through `k.toString()`.
      // That silently turned the Dart map {1: 'one'} into the Python dict
      // {'1': 'one'} — a different dict, with no error. Only string keys were
      // expressible then; pairs carry any key monty accepts.
      final got = MontyValue.fromDart({1: 'one', 2: 'two'});
      expect(
        got,
        const MontyDict([
          (MontyInt(1), MontyString('one')),
          (MontyInt(2), MontyString('two')),
        ]),
      );
    });

    test('throws for unsupported runtime types', () {
      expect(
        () => MontyValue.fromDart(Object()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ------------------------------------------------------------------
  // Cross-type checks
  // ------------------------------------------------------------------

  group('cross-type', () {
    test('distinct subtypes compare equal only where Python says so', () {
      // Smoke check on a representative sample. Python's equal pairs across
      // classes are the numeric tower (`0 == 0.0`), set == frozenset and
      // tuple == named tuple; the others, here, never compare equal.
      final samples = <MontyValue>[
        const MontyNone(),
        const MontyBool(true),
        const MontyInt(0),
        const MontyFloat(0.5),
        const MontyString(''),
        const MontyBytes([]),
        const MontyList([]),
        const MontyTuple([]),
        const MontyDict([]),
        const MontySet([]),
        const MontyDate(year: 1, month: 1, day: 1),
        const MontyTimeDelta(days: 0, seconds: 0),
        const MontyTimeZone(offsetSeconds: 0),
        MontyPath(''),
      ];
      for (var i = 0; i < samples.length; i++) {
        for (var j = 0; j < samples.length; j++) {
          if (i == j) continue;
          expect(
            samples[i] == samples[j],
            isFalse,
            reason:
                '${samples[i].runtimeType} should not equal '
                '${samples[j].runtimeType}',
          );
        }
      }
    });
  });
}
