// Unit tests for the 18 MontyValue subtypes — equality, hashCode,
// JSON round-trip, and dartValue projection.
//
// Pure value-level tests: no interpreter, no FFI, no WASM. Catches
// regressions in deep-equality, JSON shape drift, and the
// MontyValue.fromJson __type dispatcher without needing the
// integration harness to fire.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Shorthand: assert a value JSON-round-trips back to itself.
void _expectRoundTrip(MontyValue v) {
  expect(MontyValue.fromJson(v.toJson()), v);
}

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

    test('toJson is null and round-trips', () {
      const a = MontyNone();
      expect(a.toJson(), isNull);
      _expectRoundTrip(a);
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

    test('not equal to other MontyValue subtypes', () {
      expect(const MontyBool(true), isNot(const MontyInt(1)));
    });

    test('toJson + dartValue + round-trip', () {
      expect(const MontyBool(true).toJson(), true);
      expect(const MontyBool(false).dartValue, false);
      _expectRoundTrip(const MontyBool(true));
      _expectRoundTrip(const MontyBool(false));
    });
  });

  group('MontyInt', () {
    test('equality + hashCode', () {
      const a = MontyInt(42);
      const b = MontyInt(42);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const MontyInt(43)));
      expect(const MontyInt(0), isNot(const MontyBool(false)));
    });

    test('toJson + dartValue + round-trip', () {
      expect(const MontyInt(42).toJson(), 42);
      expect(const MontyInt(-7).dartValue, -7);
      _expectRoundTrip(const MontyInt(0));
      _expectRoundTrip(const MontyInt(-42));
      _expectRoundTrip(const MontyInt(0x7FFFFFFFFFFFFFFF));
    });
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

    test('toJson encodes specials as strings', () {
      expect(const MontyFloat(double.nan).toJson(), 'NaN');
      expect(const MontyFloat(double.infinity).toJson(), 'Infinity');
      expect(const MontyFloat(double.negativeInfinity).toJson(), '-Infinity');
      expect(const MontyFloat(3.14).toJson(), 3.14);
    });

    test('round-trip preserves regular values and specials', () {
      _expectRoundTrip(const MontyFloat(3.14));
      _expectRoundTrip(const MontyFloat(0));
      _expectRoundTrip(const MontyFloat(-1.5));
      _expectRoundTrip(const MontyFloat(double.nan));
      _expectRoundTrip(const MontyFloat(double.infinity));
      _expectRoundTrip(const MontyFloat(double.negativeInfinity));
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

    test('toJson + dartValue + round-trip', () {
      expect(const MontyString('hello').toJson(), 'hello');
      expect(const MontyString('').dartValue, '');
      _expectRoundTrip(const MontyString('hello'));
      _expectRoundTrip(const MontyString(''));
      _expectRoundTrip(const MontyString('unicode: π α 🎉'));
    });

    test(
      'special-float strings are NOT mistaken for strings on round-trip',
      () {
        // NaN-as-string is parsed back as MontyFloat by fromJson — that's the
        // intended escape encoding. A genuine MontyString('NaN') would
        // round-trip differently. Document the limit:
        final got = MontyValue.fromJson(const MontyString('NaN').toJson());
        expect(got, isA<MontyFloat>());
      },
    );
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

    test('round-trip preserves bytes', () {
      _expectRoundTrip(const MontyBytes([0, 127, 255]));
      _expectRoundTrip(const MontyBytes([]));
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

    test('round-trip preserves nested heterogeneous values', () {
      _expectRoundTrip(
        const MontyList([
          MontyInt(1),
          MontyString('x'),
          MontyList([MontyBool(true), MontyNone()]),
        ]),
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

    test('round-trip', () {
      _expectRoundTrip(
        const MontyTuple([MontyInt(1), MontyString('a'), MontyBool(false)]),
      );
    });
  });

  group('MontyDict', () {
    test('equality + hashCode (deep)', () {
      const a = MontyDict({'k': MontyInt(1)});
      const b = MontyDict({'k': MontyInt(1)});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different key order on the same map is still equal', () {
      // Dart Map equality semantics — same key/value pairs.
      const a = MontyDict({'a': MontyInt(1), 'b': MontyInt(2)});
      const b = MontyDict({'b': MontyInt(2), 'a': MontyInt(1)});
      expect(a, b);
    });

    test('toJson preserves the entry shape (no __type)', () {
      expect(
        const MontyDict({'k': MontyInt(1), 's': MontyString('x')}).toJson(),
        {'k': 1, 's': 'x'},
      );
    });

    test('round-trip via fromJson dispatcher (no __type → MontyDict)', () {
      _expectRoundTrip(
        const MontyDict({
          'k': MontyInt(1),
          'nested': MontyList([MontyInt(2), MontyInt(3)]),
        }),
      );
    });

    test('dartValue recursively projects', () {
      expect(
        const MontyDict({'a': MontyInt(1), 'b': MontyString('x')}).dartValue,
        {'a': 1, 'b': 'x'},
      );
    });
  });

  group('MontySet', () {
    test(
      'equality + hashCode (treated as ordered list under deep equality)',
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

    test('round-trip', () {
      _expectRoundTrip(const MontySet([MontyInt(1), MontyInt(2), MontyInt(3)]));
    });

    test('not equal to a MontyFrozenSet with the same items', () {
      const s = MontySet([MontyInt(1)]);
      const fs = MontyFrozenSet([MontyInt(1)]);
      expect(s, isNot(fs));
    });
  });

  group('MontyFrozenSet', () {
    test('equality + hashCode', () {
      const a = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      const b = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('round-trip', () {
      _expectRoundTrip(
        const MontyFrozenSet([MontyInt(1), MontyString('x')]),
      );
    });
  });

  // ------------------------------------------------------------------
  // DateTime types
  // ------------------------------------------------------------------

  group('MontyDate', () {
    test('equality + hashCode + round-trip', () {
      const a = MontyDate(year: 2026, month: 4, day: 28);
      const b = MontyDate(year: 2026, month: 4, day: 28);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      _expectRoundTrip(a);
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

    test('round-trip preserves microsecond + tz fields', () {
      _expectRoundTrip(
        const MontyDateTime(
          year: 2026,
          month: 4,
          day: 28,
          hour: 15,
          minute: 30,
          second: 45,
          microsecond: 123456,
          offsetSeconds: -28800,
          timezoneName: 'PST',
        ),
      );
    });

    test('round-trip omits null tz fields cleanly', () {
      _expectRoundTrip(
        const MontyDateTime(
          year: 2026,
          month: 4,
          day: 28,
          hour: 0,
          minute: 0,
          second: 0,
        ),
      );
    });
  });

  group('MontyTimeDelta', () {
    test('equality + hashCode', () {
      const a = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      const b = MontyTimeDelta(days: 1, seconds: 3600, microseconds: 500);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('round-trip', () {
      _expectRoundTrip(const MontyTimeDelta(days: 5, seconds: 0));
      _expectRoundTrip(
        const MontyTimeDelta(days: -1, seconds: 86399, microseconds: 999999),
      );
    });

    test('dartValue is a Duration', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 3600).dartValue,
        const Duration(days: 1, seconds: 3600),
      );
    });
  });

  group('MontyTimeZone', () {
    test('equality + hashCode + round-trip (named)', () {
      const a = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      const b = MontyTimeZone(offsetSeconds: -28800, name: 'PST');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      _expectRoundTrip(a);
    });

    test('round-trip preserves null name', () {
      _expectRoundTrip(const MontyTimeZone(offsetSeconds: 0));
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
    test('equality + hashCode + round-trip', () {
      const a = MontyPath('/data/hello.txt');
      const b = MontyPath('/data/hello.txt');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      _expectRoundTrip(a);
    });

    test('dartValue is the path string', () {
      expect(const MontyPath('/etc').dartValue, '/etc');
    });

    test('different paths are not equal', () {
      expect(const MontyPath('/a'), isNot(const MontyPath('/b')));
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

    test('different typeName is not equal (even with identical fields)', () {
      const a = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      const b = MontyNamedTuple(
        typeName: 'Vec',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      expect(a, isNot(b));
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

    test('round-trip preserves typeName, fieldNames, values', () {
      _expectRoundTrip(
        const MontyNamedTuple(
          typeName: 'sys.version_info',
          fieldNames: ['major', 'minor', 'micro', 'releaselevel', 'serial'],
          values: [
            MontyInt(3),
            MontyInt(14),
            MontyInt(0),
            MontyString('final'),
            MontyInt(0),
          ],
        ),
      );
    });

    test('dartValue exposes the toJson map', () {
      const nt = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(nt.dartValue, nt.toJson());
    });

    test('_fromMap tolerates missing fields (defaults to empty)', () {
      // Round-trip via fromJson with an under-populated payload.
      final got = MontyValue.fromJson(<String, dynamic>{
        '__type': 'namedtuple',
      });
      expect(got, isA<MontyNamedTuple>());
      final nt = got as MontyNamedTuple;
      expect(nt.typeName, '');
      expect(nt.fieldNames, isEmpty);
      expect(nt.values, isEmpty);
    });
  });

  group('MontyDataclass', () {
    test('equality + hashCode + round-trip (incl. frozen flag)', () {
      const a = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {'name': MontyString('alice'), 'age': MontyInt(30)},
        frozen: true,
      );
      const b = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {'name': MontyString('alice'), 'age': MontyInt(30)},
        frozen: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      _expectRoundTrip(a);
    });

    test('different frozen flag is not equal', () {
      const a = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name'],
        attrs: {'name': MontyString('alice')},
      );
      const b = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name'],
        attrs: {'name': MontyString('alice')},
        frozen: true,
      );
      expect(a, isNot(b));
    });

    test('different typeId is not equal', () {
      const a = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: [],
        attrs: {},
      );
      const b = MontyDataclass(
        name: 'User',
        typeId: 2,
        fieldNames: [],
        attrs: {},
      );
      expect(a, isNot(b));
    });
  });

  // ------------------------------------------------------------------
  // MontyValue.fromJson dispatcher + MontyValue.fromDart
  // ------------------------------------------------------------------

  group('MontyValue.fromJson', () {
    test('null → MontyNone', () {
      expect(MontyValue.fromJson(null), const MontyNone());
    });

    test('bool / int / double → matching scalar', () {
      expect(MontyValue.fromJson(true), const MontyBool(true));
      expect(MontyValue.fromJson(42), const MontyInt(42));
      expect(MontyValue.fromJson(3.14), const MontyFloat(3.14));
    });

    test('string with no special-float marker → MontyString', () {
      expect(MontyValue.fromJson('hi'), const MontyString('hi'));
    });

    test('special-float marker strings → MontyFloat', () {
      expect(MontyValue.fromJson('NaN'), isA<MontyFloat>());
      expect(
        MontyValue.fromJson('Infinity'),
        const MontyFloat(double.infinity),
      );
      expect(
        MontyValue.fromJson('-Infinity'),
        const MontyFloat(double.negativeInfinity),
      );
    });

    test('plain List → MontyList', () {
      final got = MontyValue.fromJson(<dynamic>[1, 'x']);
      expect(got, const MontyList([MontyInt(1), MontyString('x')]));
    });

    test('Map without __type → MontyDict', () {
      final got = MontyValue.fromJson(<String, dynamic>{'k': 1});
      expect(got, const MontyDict({'k': MontyInt(1)}));
    });

    test('Map with unknown __type falls back to MontyDict', () {
      // Defensive path: a future Rust-side type unknown to this Dart
      // version should still surface as a structurally-valid dict
      // rather than throwing. The whole map (including __type) is
      // wrapped — that's the documented contract of _parseMap.
      final got = MontyValue.fromJson(<String, dynamic>{
        '__type': 'unknown_future_type',
        'value': 1,
      });
      expect(got, isA<MontyDict>());
    });

    test('throws for unsupported runtime types', () {
      expect(
        () => MontyValue.fromJson(Object()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

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

    test('Dart List → MontyList with recursive conversion', () {
      final got = MontyValue.fromDart([1, 'x', true]);
      expect(
        got,
        const MontyList([MontyInt(1), MontyString('x'), MontyBool(true)]),
      );
    });

    test('Dart Map → MontyDict with stringified keys + recursive values', () {
      final got = MontyValue.fromDart({'k': 1, 'n': null});
      expect(got, const MontyDict({'k': MontyInt(1), 'n': MontyNone()}));
    });

    test('Map with non-String keys coerces via toString()', () {
      final got = MontyValue.fromDart({1: 'one', 2: 'two'});
      expect(
        got,
        const MontyDict({'1': MontyString('one'), '2': MontyString('two')}),
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
    test('MontyValue subtypes never compare equal across distinct types', () {
      // Smoke check on a representative sample. The sealed hierarchy
      // means any pair of distinct concrete subtypes must not be ==.
      const samples = <MontyValue>[
        MontyNone(),
        MontyBool(true),
        MontyInt(0),
        MontyFloat(0),
        MontyString(''),
        MontyBytes([]),
        MontyList([]),
        MontyTuple([]),
        MontyDict({}),
        MontySet([]),
        MontyFrozenSet([]),
        MontyDate(year: 1, month: 1, day: 1),
        MontyTimeDelta(days: 0, seconds: 0),
        MontyTimeZone(offsetSeconds: 0),
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
