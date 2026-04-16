// Unit tests for MontyValue serialisation — fromJson, fromDart, toJson,
// dartValue, equality, and hashCode for every subtype.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  group('MontyNull', () {
    test('fromJson(null) returns MontyNull', () {
      expect(MontyValue.fromJson(null), isA<MontyNull>());
    });

    test('toJson returns null', () {
      expect(const MontyNull().toJson(), isNull);
    });

    test('dartValue is null', () {
      expect(const MontyNull().dartValue, isNull);
    });

    test('equality', () {
      expect(const MontyNull(), equals(const MontyNull()));
    });

    test('hashCode matches null', () {
      expect(const MontyNull().hashCode, equals(null.hashCode));
    });

    test('toString', () {
      expect(const MontyNull().toString(), 'MontyNull()');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyBool', () {
    test('fromJson(true)', () {
      expect(MontyValue.fromJson(true), equals(const MontyBool(true)));
    });

    test('fromJson(false)', () {
      expect(MontyValue.fromJson(false), equals(const MontyBool(false)));
    });

    test('toJson round-trip true', () {
      expect(const MontyBool(true).toJson(), isTrue);
    });

    test('toJson round-trip false', () {
      expect(const MontyBool(false).toJson(), isFalse);
    });

    test('dartValue', () {
      expect(const MontyBool(true).dartValue, isTrue);
    });

    test('equality', () {
      expect(const MontyBool(true), equals(const MontyBool(true)));
      expect(const MontyBool(true), isNot(equals(const MontyBool(false))));
    });
  });

  // -------------------------------------------------------------------------
  group('MontyInt', () {
    test('fromJson positive', () {
      expect(MontyValue.fromJson(42), equals(const MontyInt(42)));
    });

    test('fromJson zero', () {
      expect(MontyValue.fromJson(0), equals(const MontyInt(0)));
    });

    test('fromJson negative', () {
      expect(MontyValue.fromJson(-7), equals(const MontyInt(-7)));
    });

    test('toJson round-trip', () {
      expect(const MontyInt(99).toJson(), 99);
    });

    test('dartValue', () {
      expect(const MontyInt(5).dartValue, 5);
    });

    test('equality', () {
      expect(const MontyInt(1), equals(const MontyInt(1)));
      expect(const MontyInt(1), isNot(equals(const MontyInt(2))));
    });
  });

  // -------------------------------------------------------------------------
  group('MontyFloat', () {
    test('fromJson regular double', () {
      expect(MontyValue.fromJson(3.14), equals(const MontyFloat(3.14)));
    });

    test('fromJson "NaN" string', () {
      final v = MontyValue.fromJson('NaN');
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value.isNaN, isTrue);
    });

    test('fromJson "Infinity" string', () {
      expect(
        MontyValue.fromJson('Infinity'),
        equals(const MontyFloat(double.infinity)),
      );
    });

    test('fromJson "-Infinity" string', () {
      expect(
        MontyValue.fromJson('-Infinity'),
        equals(const MontyFloat(double.negativeInfinity)),
      );
    });

    test('toJson NaN returns "NaN"', () {
      expect(const MontyFloat(double.nan).toJson(), 'NaN');
    });

    test('toJson Infinity returns "Infinity"', () {
      expect(const MontyFloat(double.infinity).toJson(), 'Infinity');
    });

    test('toJson -Infinity returns "-Infinity"', () {
      expect(
        const MontyFloat(double.negativeInfinity).toJson(),
        '-Infinity',
      );
    });

    test('toJson regular double returns double', () {
      expect(const MontyFloat(1.5).toJson(), 1.5);
    });

    test('NaN equals NaN', () {
      expect(
        const MontyFloat(double.nan),
        equals(const MontyFloat(double.nan)),
      );
    });

    test('NaN hashCode is stable', () {
      expect(
        const MontyFloat(double.nan).hashCode,
        equals(const MontyFloat(double.nan).hashCode),
      );
    });

    test('dartValue', () {
      expect(const MontyFloat(2.5).dartValue, 2.5);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyString', () {
    test('fromJson regular string', () {
      expect(MontyValue.fromJson('hello'), equals(const MontyString('hello')));
    });

    test('fromJson empty string', () {
      expect(MontyValue.fromJson(''), equals(const MontyString('')));
    });

    test('fromJson unicode', () {
      expect(
        MontyValue.fromJson('日本語'),
        equals(const MontyString('日本語')),
      );
    });

    test('toJson round-trip', () {
      expect(const MontyString('hi').toJson(), 'hi');
    });

    test('dartValue', () {
      expect(const MontyString('x').dartValue, 'x');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyList', () {
    test('fromJson empty list', () {
      expect(MontyValue.fromJson(<dynamic>[]), equals(const MontyList([])));
    });

    test('fromJson list of ints', () {
      expect(
        MontyValue.fromJson([1, 2, 3]),
        equals(const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)])),
      );
    });

    test('toJson round-trip', () {
      const v = MontyList([MontyInt(1), MontyBool(true)]);
      expect(v.toJson(), [1, true]);
    });

    test('dartValue unwraps elements', () {
      const v = MontyList([MontyInt(7)]);
      expect(v.dartValue, [7]);
    });

    test('nested list', () {
      final v = MontyValue.fromJson([
        [1, 2],
        [3],
      ]);
      expect(
        v,
        equals(
          const MontyList([
            MontyList([MontyInt(1), MontyInt(2)]),
            MontyList([MontyInt(3)]),
          ]),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('MontyDict', () {
    test('fromJson empty map', () {
      expect(
        MontyValue.fromJson(<String, dynamic>{}),
        equals(const MontyDict({})),
      );
    });

    test('fromJson map without __type', () {
      expect(
        MontyValue.fromJson({'a': 1, 'b': true}),
        equals(
          const MontyDict({
            'a': MontyInt(1),
            'b': MontyBool(true),
          }),
        ),
      );
    });

    test('toJson round-trip', () {
      const v = MontyDict({'x': MontyInt(5)});
      expect(v.toJson(), {'x': 5});
    });

    test('dartValue unwraps values', () {
      const v = MontyDict({'k': MontyString('v')});
      expect(v.dartValue, {'k': 'v'});
    });
  });

  // -------------------------------------------------------------------------
  group('MontyTuple', () {
    test('fromJson with __type tuple', () {
      final v = MontyValue.fromJson({
        '__type': 'tuple',
        'value': [1, 2],
      });
      expect(
        v,
        equals(const MontyTuple([MontyInt(1), MontyInt(2)])),
      );
    });

    test('toJson includes __type', () {
      const v = MontyTuple([MontyInt(1)]);
      final json = v.toJson();
      expect(json['__type'], 'tuple');
      expect(json['value'], [1]);
    });
  });

  // -------------------------------------------------------------------------
  group('MontySet', () {
    test('fromJson with __type set', () {
      final v = MontyValue.fromJson({
        '__type': 'set',
        'value': [1, 2],
      });
      expect(v, isA<MontySet>());
      expect((v as MontySet).items, [const MontyInt(1), const MontyInt(2)]);
    });

    test('toJson includes __type', () {
      const v = MontySet([MontyInt(3)]);
      final json = v.toJson();
      expect(json['__type'], 'set');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyFrozenSet', () {
    test('fromJson with __type frozenset', () {
      final v = MontyValue.fromJson({
        '__type': 'frozenset',
        'value': [42],
      });
      expect(v, isA<MontyFrozenSet>());
      expect((v as MontyFrozenSet).items, [const MontyInt(42)]);
    });

    test('toJson includes __type', () {
      const v = MontyFrozenSet([MontyBool(false)]);
      final json = v.toJson();
      expect(json['__type'], 'frozenset');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyBytes', () {
    test('fromJson with __type bytes', () {
      final v = MontyValue.fromJson({
        '__type': 'bytes',
        'value': [65, 66, 67],
      });
      expect(v, isA<MontyBytes>());
      expect((v as MontyBytes).value, [65, 66, 67]);
    });

    test('toJson includes __type and value', () {
      const v = MontyBytes([1, 2, 3]);
      final json = v.toJson();
      expect(json['__type'], 'bytes');
      expect(json['value'], [1, 2, 3]);
    });

    test('dartValue returns list of ints', () {
      expect(const MontyBytes([10, 20]).dartValue, [10, 20]);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyDate', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'date',
        'year': 2024,
        'month': 3,
        'day': 15,
      });
      expect(
        v,
        equals(
          const MontyDate(year: 2024, month: 3, day: 15),
        ),
      );
    });

    test('toJson round-trip', () {
      const v = MontyDate(year: 2024, month: 1, day: 1);
      final json = v.toJson();
      expect(json['__type'], 'date');
      expect(json['year'], 2024);
      expect(json['month'], 1);
      expect(json['day'], 1);
    });

    test('dartValue returns DateTime', () {
      const v = MontyDate(year: 2024, month: 6, day: 1);
      expect(v.dartValue, DateTime(2024, 6));
    });
  });

  // -------------------------------------------------------------------------
  group('MontyDateTime', () {
    test('fromJson with microseconds', () {
      final v = MontyValue.fromJson({
        '__type': 'datetime',
        'year': 2024,
        'month': 1,
        'day': 2,
        'hour': 10,
        'minute': 30,
        'second': 0,
        'microsecond': 500000,
        'offset_seconds': null,
        'timezone_name': null,
      });
      expect(v, isA<MontyDateTime>());
      final dt = v as MontyDateTime;
      expect(dt.microsecond, 500000);
      expect(dt.offsetSeconds, isNull);
    });

    test('microsecond defaults to 0', () {
      final v = MontyValue.fromJson({
        '__type': 'datetime',
        'year': 2024,
        'month': 1,
        'day': 1,
        'hour': 0,
        'minute': 0,
        'second': 0,
      });
      expect((v as MontyDateTime).microsecond, 0);
    });

    test('toJson preserves all fields', () {
      const v = MontyDateTime(
        year: 2024,
        month: 12,
        day: 31,
        hour: 23,
        minute: 59,
        second: 58,
        microsecond: 1,
      );
      final json = v.toJson();
      expect(json['__type'], 'datetime');
      expect(json['microsecond'], 1);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyTimeDelta', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'timedelta',
        'days': 1,
        'seconds': 3600,
        'microseconds': 0,
      });
      expect(
        v,
        equals(
          const MontyTimeDelta(days: 1, seconds: 3600),
        ),
      );
    });

    test('toJson round-trip', () {
      const v = MontyTimeDelta(days: 2, seconds: 0, microseconds: 500);
      final json = v.toJson();
      expect(json['__type'], 'timedelta');
      expect(json['microseconds'], 500);
    });

    test('dartValue returns Duration', () {
      const v = MontyTimeDelta(days: 1, seconds: 0);
      expect(v.dartValue, const Duration(days: 1));
    });
  });

  // -------------------------------------------------------------------------
  group('MontyPath', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'path',
        'value': '/tmp/file.txt',
      });
      expect(v, equals(const MontyPath('/tmp/file.txt')));
    });

    test('toJson includes __type', () {
      const v = MontyPath('/etc/hosts');
      final json = v.toJson();
      expect(json['__type'], 'path');
      expect(json['value'], '/etc/hosts');
    });

    test('dartValue returns string', () {
      expect(const MontyPath('/a/b').dartValue, '/a/b');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyNamedTuple', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'namedtuple',
        'type_name': 'Point',
        'field_names': ['x', 'y'],
        'values': [1, 2],
      });
      expect(v, isA<MontyNamedTuple>());
      final nt = v as MontyNamedTuple;
      expect(nt.typeName, 'Point');
      expect(nt.fieldNames, ['x', 'y']);
      expect(nt.values, [const MontyInt(1), const MontyInt(2)]);
    });

    test('toJson round-trip', () {
      const v = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['a'],
        values: [MontyInt(5)],
      );
      final json = v.toJson();
      expect(json['__type'], 'namedtuple');
      expect(json['type_name'], 'P');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyDataclass', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'dataclass',
        'name': 'Foo',
        'type_id': 1,
        'field_names': ['bar'],
        'attrs': {'bar': 42},
        'frozen': false,
      });
      expect(v, isA<MontyDataclass>());
      final dc = v as MontyDataclass;
      expect(dc.name, 'Foo');
      expect(dc.attrs['bar'], const MontyInt(42));
    });

    test('frozen field preserved', () {
      final v = MontyValue.fromJson({
        '__type': 'dataclass',
        'name': 'F',
        'type_id': 2,
        'field_names': <String>[],
        'attrs': <String, dynamic>{},
        'frozen': true,
      });
      expect((v as MontyDataclass).frozen, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyValue.fromDart', () {
    test('null → MontyNull', () {
      expect(MontyValue.fromDart(null), isA<MontyNull>());
    });

    test('bool → MontyBool', () {
      expect(MontyValue.fromDart(true), equals(const MontyBool(true)));
    });

    test('int → MontyInt', () {
      expect(MontyValue.fromDart(3), equals(const MontyInt(3)));
    });

    test('double → MontyFloat', () {
      expect(MontyValue.fromDart(1.5), equals(const MontyFloat(1.5)));
    });

    test('String → MontyString', () {
      expect(
        MontyValue.fromDart('hi'),
        equals(const MontyString('hi')),
      );
    });

    test('List → MontyList', () {
      expect(
        MontyValue.fromDart([1, 2]),
        equals(const MontyList([MontyInt(1), MontyInt(2)])),
      );
    });

    test('Map → MontyDict', () {
      expect(
        MontyValue.fromDart({'k': 'v'}),
        equals(const MontyDict({'k': MontyString('v')})),
      );
    });

    test('MontyValue passthrough', () {
      const v = MontyInt(7);
      expect(MontyValue.fromDart(v), same(v));
    });

    test('nested list/map', () {
      final v = MontyValue.fromDart({
        'items': [1, null],
      });
      expect(v, isA<MontyDict>());
      final d = v as MontyDict;
      final items = d.entries['items']! as MontyList;
      expect(items.items[0], const MontyInt(1));
      expect(items.items[1], const MontyNull());
    });

    test('unsupported type throws ArgumentError', () {
      expect(() => MontyValue.fromDart(Object()), throwsArgumentError);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyValue.fromJson unknown __type', () {
    test('falls back to MontyDict (unknown type preserved)', () {
      // Unknown __type is not an error — returns a dict with the __type key
      final v = MontyValue.fromJson({'__type': 'unknown_future_type'});
      expect(v, isA<MontyDict>());
    });
  });

  group('MontyValue.fromJson unsupported primitive', () {
    test('throws ArgumentError for unsupported runtime type', () {
      // fromJson only handles null/bool/int/double/String/List/Map
      expect(() => MontyValue.fromJson(Object()), throwsArgumentError);
    });
  });
}
