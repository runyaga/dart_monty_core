// WASM integration tests: date.today / datetime.now OS call dispatch.
//
// Covers monty v0.0.14 additions OsFunction::DateToday,
// OsFunction::DateTimeNow, and ExtFunctionResult::NotFound on WASM.
//
// Run with dart2js:  dart test test/integration/wasm_datetime_oscall_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_datetime_oscall_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

const _kYear = 2024;
const _kMonth = 1;
const _kDay = 15;
const _kHour = 10;
const _kMinute = 30;
const _kSecond = 0;

MontyDate _fixedDate() =>
    const MontyDate(year: _kYear, month: _kMonth, day: _kDay);

MontyDateTime _fixedDateTime({int? offsetSeconds, String? timezoneName}) =>
    MontyDateTime(
      year: _kYear,
      month: _kMonth,
      day: _kDay,
      hour: _kHour,
      minute: _kMinute,
      second: _kSecond,
      offsetSeconds: offsetSeconds,
      timezoneName: timezoneName,
    );

OsCallHandler _datetimeHandler() => (op, args, kwargs) async {
  switch (op) {
    case 'date.today':
      return _fixedDate();
    case 'datetime.now':
      final tzArg = args.isNotEmpty ? args.first : null;
      if (tzArg == null) return _fixedDateTime();
      final tz = tzArg as Map<String, Object?>;
      return _fixedDateTime(
        offsetSeconds: (tz['offset_seconds']! as num).toInt(),
        timezoneName: tz['name'] as String?,
      );
    default:
      throw OsCallException('$op not supported');
  }
};

void main() {
  group('wasm_datetime_oscall', () {
    test('date.today() returns MontyDate with fixed fields', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feed(
        'datetime.date.today()',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(
        result.value,
        const MontyDate(year: _kYear, month: _kMonth, day: _kDay),
      );
    });

    test('datetime.now() is naive (tzinfo is None)', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feed(
        'datetime.datetime.now().tzinfo is None',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyBool(true));
    });

    test('datetime.now(timezone.utc) preserves UTC tzinfo', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feed(
        'datetime.datetime.now(datetime.timezone.utc)'
        '.tzinfo is datetime.timezone.utc',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyBool(true));
    });

    test(
      'OsCallNotHandledException surfaces Python NameError (not RuntimeError)',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        OsCallHandler notHandled() =>
            (op, args, kwargs) async => throw const OsCallNotHandledException();

        await repl.feed('import datetime', osHandler: notHandled());
        final error = await repl
            .feed('datetime.date.today()', osHandler: notHandled())
            .then<MontyScriptError?>((_) => null)
            .catchError((Object e) => e as MontyScriptError?);

        expect(error, isNotNull);
        expect(error?.excType, 'NameError');
        expect(error?.message, contains('date.today'));
      },
    );

    test(
      'OsCallException surfaces Python RuntimeError (contrast with NameError)',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        OsCallHandler alwaysFails() =>
            (op, args, kwargs) async =>
                throw const OsCallException('handler refused');

        await repl.feed('import datetime', osHandler: alwaysFails());
        final error = await repl
            .feed('datetime.date.today()', osHandler: alwaysFails())
            .then<MontyScriptError?>((_) => null)
            .catchError((Object e) => e as MontyScriptError?);

        expect(error, isNotNull);
        expect(error?.excType, 'RuntimeError');
        expect(error?.message, contains('handler refused'));
      },
    );
  });
}
