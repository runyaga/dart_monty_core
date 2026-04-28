// Integration tests: date.today / datetime.now OS call dispatch.
//
// Covers monty v0.0.14 additions OsFunction::DateToday and
// OsFunction::DateTimeNow. The host returns MontyDate / MontyDateTime from
// the OsCallHandler and the Rust layer reconstructs the Python objects.
//
// Run: dart test test/integration/ffi_datetime_oscall_test.dart -p vm
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Deterministic fixture date — avoids wall-clock flakiness.
// ---------------------------------------------------------------------------

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
      // Single positional arg is the tz: MontyTimeZone (as JSON map via
      // dartValue) or null for a naive datetime.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ffi_datetime_oscall', () {
    test('date.today() returns MontyDate with fixed fields', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedRun('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feedRun(
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

      await repl.feedRun('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feedRun(
        'datetime.datetime.now().tzinfo is None',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyBool(true));
    });

    test('datetime.now(timezone.utc) preserves UTC tzinfo', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedRun('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feedRun(
        'datetime.datetime.now(datetime.timezone.utc)'
        '.tzinfo is datetime.timezone.utc',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyBool(true));
    });

    test('datetime.now(fixed offset) preserves tzinfo equality', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedRun('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feedRun(
        'plus_two = datetime.timezone(datetime.timedelta(hours=2))\n'
        'now = datetime.datetime.now(plus_two)\n'
        'now.tzinfo == plus_two',
        osHandler: _datetimeHandler(),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyBool(true));
    });

    test('datetime.now() and date.today() agree on calendar date', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedRun('import datetime', osHandler: _datetimeHandler());
      final result = await repl.feedRun(
        'today = datetime.date.today()\n'
        'now = datetime.datetime.now()\n'
        'str(now).startswith(str(today))',
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

        await repl.feedRun('import datetime', osHandler: notHandled());
        final error = await repl
            .feedRun('datetime.date.today()', osHandler: notHandled())
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

        await repl.feedRun('import datetime', osHandler: alwaysFails());
        final error = await repl
            .feedRun('datetime.date.today()', osHandler: alwaysFails())
            .then<MontyScriptError?>((_) => null)
            .catchError((Object e) => e as MontyScriptError?);

        expect(error, isNotNull);
        expect(error?.excType, 'RuntimeError');
        expect(error?.message, contains('handler refused'));
      },
    );
  });
}
