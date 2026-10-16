// Tests for the date, time and structured members of the MontyValue family.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_monty_value_support.dart';

MontyValue _roundTrip(MontyValue value) {
  final writer = ArenaWriter();
  final root = writer.add(value);

  return ArenaReader(pb.Arena.fromBuffer(writer.arena.writeToBuffer()))[root];
}

/// Whether [hashes] are not all one value: the input varied takes part in
/// the hash. (The statements do not promise that two particular values differ.)
bool _varies(Iterable<int> hashes) => hashes.toSet().length > 1;

/// A fresh string: a `const` twin is the same object.
MontyString _str(String v) => MontyString(v);

int _id(int v) => v;

MontyDate _date(int y, int m, int d) => MontyDate(year: y, month: m, day: d);

MontyTimeDelta _td(int d, int s, int us) =>
    MontyTimeDelta(days: d, seconds: s, microseconds: us);

MontyDateTime _dt({
  int year = 2024,
  int month = 3,
  int day = 5,
  int hour = 7,
  int minute = 8,
  int second = 9,
  int microsecond = 0,
  int? offsetSeconds,
}) => MontyDateTime(
  year: year,
  month: month,
  day: day,
  hour: hour,
  minute: minute,
  second: second,
  microsecond: microsecond,
  offsetSeconds: offsetSeconds,
);

void main() {
  group('MontyDate', () {
    const date = MontyDate(year: 2024, month: 3, day: 5);

    test(
      'equal on year, month and day; hash of the three',
      () {
        final d = _date(2024, 3, 5);
        expect(d == _date(2024, 3, 5), isTrue);
        expect(d == _date(2025, 3, 5), isFalse);
        expect(d == _date(2024, 4, 5), isFalse);
        expect(d == _date(2024, 3, 6), isFalse);
        expect(d.hashCode, _date(2024, 3, 5).hashCode);
        // Each field takes part in the hash.
        expect(
          _varies([for (var y = 1; y < 40; y++) _date(y, 3, 5).hashCode]),
          isTrue,
          reason: 'year',
        );
        expect(
          _varies([for (var m = 1; m < 13; m++) _date(2024, m, 5).hashCode]),
          isTrue,
          reason: 'month',
        );
        expect(
          _varies([for (var v = 1; v < 29; v++) _date(2024, 3, v).hashCode]),
          isTrue,
          reason: 'day',
        );
      },
    );
    test('unequal to datetimes and numeric wrappers', () {
      const midnight = MontyDateTime(
        year: 2024,
        month: 3,
        day: 5,
        hour: 0,
        minute: 0,
        second: 0,
      );
      expect(date == midnight, isFalse);
      expect(midnight == date, isFalse);
      const one = MontyDate(year: 1, month: 1, day: 1);
      for (final n in <MontyValue>[
        const MontyInt(1),
        const MontyBool(true),
        const MontyFloat(1),
        MontyBigInt(BigInt.one),
        const MontyComplex(1, 0),
        const MontyInt(0),
        const MontyBool(false),
      ]) {
        expect(one == n, isFalse, reason: '$n');
        expect(n == one, isFalse, reason: '$n');
      }
    });
    test('fromDart returns an existing MontyDate', () {
      final v = _date(2024, 3, 5);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test(
      'fromDart of its DateTime gives a MontyDateTime',
      () {
        final back = MontyValue.fromDart(date.dartValue);
        expect(back, isA<MontyDateTime>());
        expect(back, isNot(isA<MontyDate>()));
        final dt = back as MontyDateTime;
        expect((dt.year, dt.month, dt.day), (2024, 3, 5));
        expect((dt.hour, dt.minute, dt.second, dt.microsecond), (0, 0, 0, 0));
        expect(dt.offsetSeconds, isNotNull);
        expect(back == date, isFalse);
      },
    );
    test('the constructor stores without validating', () {
      const d = MontyDate(year: -5, month: 13, day: 99);
      expect((d.year, d.month, d.day), (-5, 13, 99));
      const z = MontyDate(year: 0, month: 0, day: 0);
      expect((z.year, z.month, z.day), (0, 0, 0));
    });
    test('invalid components are refused when encoded', () {
      for (final bad in [
        const MontyDate(year: 2024, month: 13, day: 1),
        const MontyDate(year: 2024, month: 0, day: 1),
        const MontyDate(year: 2024, month: 2, day: 30),
        const MontyDate(year: 2024, month: 1, day: 0),
        const MontyDate(year: 0, month: 1, day: 1),
      ]) {
        expect(
          () => ArenaWriter().add(bad),
          throwsArgumentError,
          reason: '${bad.year}-${bad.month}-${bad.day}',
        );
      }
      expect(_roundTrip(date), date);
    });
  });

  group('MontyDateTime', () {
    test(
      'fromDart returns an existing MontyDateTime',
      () {
        final v = _dt(offsetSeconds: 3600);
        expect(identical(MontyValue.fromDart(v), v), isTrue);
      },
    );
    test(
      'fields are stored without range validation',
      () {
        final v = _dt(
          year: 0,
          month: 0,
          day: 40,
          hour: 99,
          minute: -1,
          second: 61,
          microsecond: 2000000,
        );
        expect(
          (v.year, v.month, v.day, v.hour, v.minute, v.second, v.microsecond),
          (0, 0, 40, 99, -1, 61, 2000000),
        );
      },
    );
  });

  group('MontyTime', () {
    test('fromDart returns an equal MontyTime', () {
      const t = MontyTime(
        hour: 1,
        minute: 2,
        second: 3,
        microsecond: 4,
        offsetSeconds: 3600,
      );
      final back = MontyValue.fromDart(t);
      expect(back, isA<MontyTime>());
      expect(back == t, isTrue);
    });
    test('naive rendering', () {
      expect(
        const MontyTime(
          hour: 1,
          minute: 2,
          second: 3,
          microsecond: 4,
        ).toString(),
        'MontyTime(1:2:3.4)',
      );
      expect(
        const MontyTime(
          hour: 12,
          minute: 30,
          second: 45,
          microsecond: 123456,
        ).toString(),
        'MontyTime(12:30:45.123456)',
      );
      expect(
        const MontyTime(
          hour: 0,
          minute: 0,
          second: 0,
          microsecond: 0,
        ).toString(),
        'MontyTime(0:0:0.0)',
      );
    });
    test('aware rendering with the offset suffix', () {
      expect(
        const MontyTime(
          hour: 1,
          minute: 2,
          second: 3,
          microsecond: 4,
          offsetSeconds: 3600,
        ).toString(),
        'MontyTime(1:2:3.4 offset=3600)',
      );
      expect(
        const MontyTime(
          hour: 10,
          minute: 0,
          second: 0,
          microsecond: 0,
          offsetSeconds: -18000,
        ).toString(),
        'MontyTime(10:0:0.0 offset=-18000)',
      );
      expect(
        const MontyTime(
          hour: 10,
          minute: 0,
          second: 0,
          microsecond: 0,
          offsetSeconds: 0,
        ).toString(),
        'MontyTime(10:0:0.0 offset=0)',
      );
    });
  });

  group('MontyTimeDelta', () {
    const td = MontyTimeDelta(days: 1, seconds: 2, microseconds: 3);

    test(
      'equal on all three fields; hash of the three',
      () {
        final t = _td(1, 2, 3);
        expect(t == _td(1, 2, 3), isTrue);
        expect(t == _td(9, 2, 3), isFalse);
        expect(t == _td(1, 9, 3), isFalse);
        expect(t == _td(1, 2, 9), isFalse);
        expect(t == const MontyInt(1), isFalse);
        final Object asDuration = t.dartValue;
        expect(t == asDuration, isFalse);
        expect(t.hashCode, _td(1, 2, 3).hashCode);
        expect(
          _varies([for (var v = 0; v < 30; v++) _td(v, 2, 3).hashCode]),
          isTrue,
          reason: 'days',
        );
        expect(
          _varies([for (var v = 0; v < 30; v++) _td(1, v, 3).hashCode]),
          isTrue,
          reason: 'seconds',
        );
        expect(
          _varies([for (var v = 0; v < 30; v++) _td(1, 2, v).hashCode]),
          isTrue,
          reason: 'microseconds',
        );
      },
    );
    test('fromDart preserves an existing timedelta', () {
      final v = _td(1, 2, 3);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('a Dart Duration is not a native input', () {
      expect(
        () => MontyValue.fromDart(const Duration(seconds: 1)),
        throwsArgumentError,
      );
      expect(
        () => MontyValue.fromDart([const Duration(days: 1)]),
        throwsArgumentError,
      );
      expect(td.dartValue, isA<Duration>());
    });
    test('rendering omits microseconds', () {
      expect(td.toString(), 'MontyTimeDelta(days=1, seconds=2)');
      expect(
        const MontyTimeDelta(
          days: -3,
          seconds: 86399,
          microseconds: 999999,
        ).toString(),
        'MontyTimeDelta(days=-3, seconds=86399)',
      );
    });
  });

  group('MontyTimeZone', () {
    test('dartValue map, with a null name key', () {
      expect(const MontyTimeZone(offsetSeconds: 3600, name: 'CET').dartValue, {
        '__type': 'timezone',
        'offset_seconds': 3600,
        'name': 'CET',
      });
      final unnamed = const MontyTimeZone(offsetSeconds: -60).dartValue;
      expect(unnamed.containsKey('name'), isTrue);
      expect(unnamed, {
        '__type': 'timezone',
        'offset_seconds': -60,
        'name': null,
      });
      expect(unnamed.keys.toSet(), {'__type', 'offset_seconds', 'name'});
    });
    test(
      'fromDart keeps it, and does not unwrap maps',
      () {
        final v = MontyTimeZone(offsetSeconds: _id(5), name: 'x');
        expect(identical(MontyValue.fromDart(v), v), isTrue);
        final back = MontyValue.fromDart(v.dartValue);
        expect(back, isNot(isA<MontyTimeZone>()));
        expect(back, isA<MontyDict>());
        expect((back as MontyDict).pairs, hasLength(3));
      },
    );
    test('MontyTimeZone(offset=<o>, name=<n>)', () {
      expect(
        const MontyTimeZone(offsetSeconds: 3600, name: 'CET').toString(),
        'MontyTimeZone(offset=3600, name=CET)',
      );
      expect(
        const MontyTimeZone(offsetSeconds: -60).toString(),
        'MontyTimeZone(offset=-60, name=null)',
      );
    });
    test('date, time and timezone dartValue', () {
      expect(
        const MontyDate(year: 2024, month: 3, day: 5).dartValue,
        DateTime(2024, 3, 5),
      );
      expect(
        const MontyDate(year: 2024, month: 3, day: 5).dartValue.isUtc,
        isFalse,
      );
      const t = MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4);
      expect(identical(t.dartValue, t), isTrue);
      expect(const MontyTimeZone(offsetSeconds: 7, name: 'n').dartValue, {
        '__type': 'timezone',
        'offset_seconds': 7,
        'name': 'n',
      });
      expect(const MontyTimeZone(offsetSeconds: 7).dartValue, {
        '__type': 'timezone',
        'offset_seconds': 7,
        'name': null,
      });
    });
  });

  group('MontyFileHandle and MontyExceptionValue', () {
    test(
      'dartValue map with __type and three fields',
      () {
        final h = MontyFileHandle('/a/b', 'r', position: BigInt.from(5));
        expect(h.dartValue, {
          '__type': 'filehandle',
          'path': '/a/b',
          'mode': 'r',
          'position': 5,
        });
        expect(h.dartValue.keys.toSet(), {
          '__type',
          'path',
          'mode',
          'position',
        });
        expect(MontyFileHandle('/x', 'w').dartValue, {
          '__type': 'filehandle',
          'path': '/x',
          'mode': 'w',
          'position': 0,
        });
      },
    );
    test(
      'toString is the upstream repr, path and mode '
      'quoted, no position',
      () {
        expect(
          MontyFileHandle('/a', 'r').toString(),
          "MontyFileHandle(path='/a', mode='r')",
        );
        expect(
          MontyFileHandle('/b', 'wb', position: BigInt.from(7)).toString(),
          "MontyFileHandle(path='/b', mode='wb')",
        );
        // A quote in the path is escaped as Python's repr does.
        expect(
          MontyFileHandle("/it's", 'r').toString(),
          'MontyFileHandle(path="/it\'s", mode=\'r\')',
        );
      },
    );
    test(
      'compares and hashes path, mode, position',
      () {
        MontyFileHandle h(String p, String m, int pos) =>
            MontyFileHandle(p, m, position: BigInt.from(pos));
        final (base, twin) = twins(() => h('/a', 'r', 3));
        expect(base == twin, isTrue);
        expect(base == h('/b', 'r', 3), isFalse);
        expect(base == h('/a', 'w', 3), isFalse);
        expect(base == h('/a', 'r', 4), isFalse);
        expect(base.hashCode, twin.hashCode);
        expect(
          _varies([
            for (final c in 'abcdefghij'.split('')) h('/$c', 'r', 3).hashCode,
          ]),
          isTrue,
          reason: 'path',
        );
        expect(
          _varies([
            for (final m in ['r', 'w', 'a', 'rb', 'wb', 'ab'])
              h('/a', m, 3).hashCode,
          ]),
          isTrue,
          reason: 'mode',
        );
        expect(
          _varies([for (var v = 0; v < 30; v++) h('/a', 'r', v).hashCode]),
          isTrue,
          reason: 'position',
        );
      },
    );
    test('exception and file-handle fields', () {
      MontyExceptionValue e(
        String type,
        String? msg, [
        Map<String, MontyValue> attrs = const {},
      ]) => MontyExceptionValue(type, msg, attrs);
      final (a, aTwin) = twins(() => {'k': _str('v')});
      final (plain, plainTwin) = twins(() => e('E', 'm'));
      final withAttrs = e('E', 'm', a);
      expect(plain == plainTwin, isTrue);
      expect(plain == e('F', 'm'), isFalse);
      expect(plain == e('E', 'n'), isFalse);
      expect(e('E', null) == plain, isFalse);
      expect(withAttrs == e('E', 'm', aTwin), isTrue);
      expect(
        withAttrs == e('E', 'm', {'k': _str('w')}),
        isFalse,
      );
      expect(
        withAttrs == e('E', 'm', {'j': _str('v')}),
        isFalse,
      );
      expect(withAttrs == plain, isFalse);
      expect(withAttrs.hashCode, e('E', 'm', aTwin).hashCode);
      expect(plain.hashCode, plainTwin.hashCode);
      expect(
        _varies([for (final c in 'ABCDEFGH'.split('')) e(c, 'm').hashCode]),
        isTrue,
        reason: 'type',
      );
      expect(
        _varies([for (final c in 'abcdefgh'.split('')) e('E', c).hashCode]),
        isTrue,
        reason: 'message',
      );
      expect(
        _varies([
          for (final c in 'abcdefgh'.split(''))
            e('E', 'm', {'k': _str(c)}).hashCode,
        ]),
        isTrue,
        reason: 'attributes',
      );

      MontyFileHandle fh(String p, String m, int pos) =>
          MontyFileHandle(p, m, position: BigInt.from(pos));
      expect(
        _varies([
          for (final c in 'abcdefghij'.split('')) fh('/$c', 'r', 1).hashCode,
        ]),
        isTrue,
        reason: 'path',
      );
      expect(
        _varies([
          for (final m in ['r', 'w', 'a', 'rb']) fh('/a', m, 1).hashCode,
        ]),
        isTrue,
        reason: 'mode',
      );
      expect(
        _varies([for (var v = 0; v < 30; v++) fh('/a', 'r', v).hashCode]),
        isTrue,
        reason: 'position',
      );
      final h = MontyFileHandle('/a', 'r', position: BigInt.one);
      expect(h == MontyFileHandle('/a', 'r', position: BigInt.one), isTrue);
      expect(h == MontyFileHandle('/b', 'r', position: BigInt.one), isFalse);
      expect(h == MontyFileHandle('/a', 'w', position: BigInt.one), isFalse);
      expect(h == MontyFileHandle('/a', 'r', position: BigInt.two), isFalse);
      expect(
        h.hashCode,
        MontyFileHandle('/a', 'r', position: BigInt.one).hashCode,
      );
    });
  });
}
