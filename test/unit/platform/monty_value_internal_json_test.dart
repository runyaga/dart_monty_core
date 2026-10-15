// The internal tagged-JSON form of the value kinds whose wire tests went with
// the old engine: datetime, timedelta and time, reached through the internal
// MontyValueInternal accessor (toJson is no longer public), plus the repr
// and singleton members those tests also covered.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal, montyStdTypeProxy;
import 'package:test/test.dart';

void main() {
  group('internal toJson', () {
    test('datetime carries every field, offset and zone included', () {
      const value = MontyDateTime(
        year: 2024,
        month: 2,
        day: 29,
        hour: 23,
        minute: 59,
        second: 58,
        microsecond: 7,
        offsetSeconds: 3600,
        timezoneName: 'CET',
      );
      expect(value.toJson(), {
        '__type': 'datetime',
        'year': 2024,
        'month': 2,
        'day': 29,
        'hour': 23,
        'minute': 59,
        'second': 58,
        'microsecond': 7,
        'offset_seconds': 3600,
        'timezone_name': 'CET',
      });
    });

    test('timedelta carries days, seconds and microseconds', () {
      expect(
        const MontyTimeDelta(
          days: -1,
          seconds: 86399,
          microseconds: 5,
        ).toJson(),
        {
          '__type': 'timedelta',
          'days': -1,
          'seconds': 86399,
          'microseconds': 5,
        },
      );
    });

    test('time carries fold and the optional offset and zone', () {
      expect(
        const MontyTime(
          hour: 1,
          minute: 2,
          second: 3,
          microsecond: 4,
          fold: 1,
        ).toJson(),
        {
          '__type': 'time',
          'hour': 1,
          'minute': 2,
          'second': 3,
          'microsecond': 4,
          'offset_seconds': null,
          'timezone_name': null,
          'fold': 1,
        },
      );
    });
  });

  test('a named tuple prints its type name and field count', () {
    expect(
      const MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      ).toString(),
      'MontyNamedTuple(Point, 2 fields)',
    );
  });

  test('NotImplemented is one value', () {
    expect(const MontyNotImplemented(), const MontyNotImplemented());
    expect(
      const MontyNotImplemented().hashCode,
      const MontyNotImplemented().hashCode,
    );
  });

  test('a std-type proxy repr escapes control characters as Python does', () {
    expect(
      montyStdTypeProxy('function', 'a\u0001b\u007f').toString(),
      r"MontyStdTypeProxy(kind='function', name='a\x01b\x7f')",
    );
  });
}
