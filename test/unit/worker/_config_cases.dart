// The session settings against upstream's outcomes: each case of
// _config_oracle.g.dart (pydantic-monty 1.1.0) built here as core's session
// records, checked out of a real pool and, where upstream accepts it, fed
// the recorded code. Shared by the VM harness
// (test/integration/worker/pool_session_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:test/test.dart';

import '_config_oracle.g.dart';

/// 2020-07-02 03:04:05.678 UTC, the oracle's frozen instant.
final DateTime _frozen = DateTime.utc(2020, 7, 2, 3, 4, 5, 678);

SessionConfig _limits(ResourceLimits limits) => SessionConfig(limits: limits);

SessionConfig _policy(OsPolicy policy, [ResourceLimits? limits]) =>
    SessionConfig(osPolicy: policy, limits: limits);

SessionConfig _seed(RandomSeed seed) => _policy(OsPolicy(randomSeed: seed));

const Duration _negative = Duration(microseconds: -1000000);

/// The Dart form of each oracle case, by id.
final Map<String, SessionConfig> configCases = {
  'limits_negative_memory': _limits(const ResourceLimits(maxMemory: -5)),
  'limits_negative_gc_interval': _limits(const ResourceLimits(gcInterval: -1)),
  'limits_negative_recursion': _limits(
    const ResourceLimits(maxRecursionDepth: -1),
  ),
  'limits_negative_suspensions': _limits(
    const ResourceLimits(maxSuspensions: -1),
  ),
  'limits_negative_feed': _limits(
    const ResourceLimits(maxFeedDuration: _negative),
  ),
  'limits_negative_turn': _limits(
    const ResourceLimits(maxTurnDuration: _negative),
  ),
  'limits_negative_total_sleep': _limits(
    const ResourceLimits(maxTotalSleep: _negative),
  ),
  'type_check_format_unknown': const SessionConfig(
    typeCheck: true,
    typeCheckFormat: 'bogus',
  ),
  'assert_annotations_negative': const SessionConfig(
    assertMessageAnnotations: -1,
  ),
  'assert_annotations_too_big': const SessionConfig(
    assertMessageAnnotations: 0x100000000,
  ),
  'print_flush_negative': const SessionConfig(printFlushInterval: _negative),
  'datetime_unknown': _policy(const OsPolicy(datetime: 'nope')),
  'timezone_unknown': _policy(const OsPolicy(timezone: 'Not/AZone')),
  'timezone_offset_high': _policy(
    const OsPolicy(fixedTimezone: TimeZone(86400)),
  ),
  'timezone_offset_low': _policy(
    const OsPolicy(fixedTimezone: TimeZone(-86400)),
  ),
  'timezone_offset_i32_high': _policy(
    const OsPolicy(fixedTimezone: TimeZone(0x80000000)),
  ),
  'timezone_offset_i32_low': _policy(
    const OsPolicy(fixedTimezone: TimeZone(-0x80000001)),
  ),
  'timezone_offset_i32_max': _policy(
    const OsPolicy(fixedTimezone: TimeZone(0x7fffffff)),
  ),
  'timezone_offset_name_surrogate': _policy(
    const OsPolicy(fixedTimezone: TimeZone(0, name: 'a\u{d800}')),
  ),
  'timezone_offset_overflow_before_name': _policy(
    const OsPolicy(fixedTimezone: TimeZone(0x80000000, name: 'a\u{d800}')),
  ),
  'timezone_etc_unknown': _policy(const OsPolicy(timezone: 'Etc/Unknown')),
  'timezone_too_long': _policy(OsPolicy(timezone: 'Europe/${'a' * 94}')),
  'timezone_dot_part': _policy(
    const OsPolicy(timezone: 'Europe/../Europe/London'),
  ),
  'timezone_empty_part': _policy(const OsPolicy(timezone: 'Europe//London')),
  'timezone_space': _policy(const OsPolicy(timezone: 'Europe/London ')),
  'timezone_not_a_zone_file': _policy(const OsPolicy(timezone: 'zone.tab')),
  'timezone_surrogate': _policy(
    const OsPolicy(timezone: 'Europe/London\u{d800}'),
  ),
  'timezone_surrogates': _policy(
    const OsPolicy(timezone: 'x\u{dc00}\u{dc01}y'),
  ),
  'sleep_unknown': _policy(const OsPolicy(sleep: 'bad')),
  'sleep_max_negative': _policy(const OsPolicy(sleepSystemMax: _negative)),
  'sleep_max_with_zero': _policy(
    const OsPolicy(sleep: 'zero', sleepSystemMax: Duration(seconds: 1)),
  ),
  'sleep_max_with_call_host': _policy(
    const OsPolicy(sleep: 'call_host', sleepSystemMax: Duration(seconds: 1)),
  ),
  'process_time_unknown': _policy(const OsPolicy(processTime: 'x')),
  'random_start_unknown': _policy(const OsPolicy(randomStart: 'x')),
  'seed_nan': _seed(const RandomSeed.float(double.nan)),
  'seed_inf': _seed(const RandomSeed.float(double.infinity)),
  'seed_negative_inf': _seed(const RandomSeed.float(double.negativeInfinity)),
  'seed_str_surrogate': _seed(const RandomSeed.string('ab\u{dc00}')),
  'type_check_full': const SessionConfig(typeCheck: true),
  'type_check_concise': const SessionConfig(
    typeCheck: true,
    typeCheckFormat: 'concise',
  ),
  'type_check_format_upper': const SessionConfig(
    typeCheck: true,
    typeCheckFormat: 'JSON',
  ),
  'type_check_format_dashed': const SessionConfig(
    typeCheck: true,
    typeCheckFormat: 'json-lines',
  ),
  'frozen_utc': _policy(OsPolicy(fixedDatetime: _frozen)),
  'frozen_offset_named': _policy(
    OsPolicy(
      fixedDatetime: _frozen,
      fixedTimezone: const TimeZone(7200, name: 'X'),
    ),
  ),
  'frozen_offset_unnamed': _policy(
    OsPolicy(fixedDatetime: _frozen, fixedTimezone: const TimeZone(-12600)),
  ),
  // Upstream's aware datetime: in Dart, the instant and its zone apart. The
  // zone a DateTime itself implies is checked by the local-zone test below.
  'frozen_aware': _policy(
    OsPolicy(
      fixedDatetime: _frozen,
      fixedTimezone: const TimeZone(7200, name: 'X'),
    ),
  ),
  'frozen_named_zone': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'Europe/London'),
  ),
  'frozen_zone_utc_upper': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'UTC'),
  ),
  'frozen_zone_utc': _policy(OsPolicy(fixedDatetime: _frozen, timezone: 'utc')),
  'frozen_named_zone_case': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'europe/LONDON'),
  ),
  'frozen_zone_utc_mixed_case': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'uTc'),
  ),
  'frozen_zone_factory': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'Factory'),
  ),
  'frozen_zone_link': _policy(
    OsPolicy(fixedDatetime: _frozen, timezone: 'Europe/Kiev'),
  ),
  'datetime_call_host': _policy(const OsPolicy(datetime: 'call_host')),
  'seed_int': _seed(RandomSeed.integer(BigInt.from(42))),
  'seed_negative_int': _seed(RandomSeed.integer(BigInt.from(-5))),
  'seed_big_int': _seed(RandomSeed.integer(BigInt.two.pow(70))),
  'seed_float': _seed(const RandomSeed.float(1.5)),
  // On dart2js 42.0 is the int 42: the constructor keeps the kind.
  'seed_integral_float': _seed(const RandomSeed.float(42)),
  'seed_big_float': _seed(RandomSeed.float(BigInt.two.pow(70).toDouble())),
  'seed_str': _seed(const RandomSeed.string('abc')),
  'seed_bytes': _seed(RandomSeed.bytes(Uint8List.fromList(utf8.encode('abc')))),
  'random_call_host': _policy(const OsPolicy(randomStart: 'call_host')),
  'process_time_zero': _policy(const OsPolicy(processTime: 'zero')),
  'process_time_elapsed': _policy(const OsPolicy(processTime: 'elapsed')),
  'sleep_zero': _policy(
    const OsPolicy(sleep: 'zero'),
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 1)),
  ),
  'sleep_call_host': _policy(const OsPolicy(sleep: 'call_host')),
  'total_sleep_exceeded': _limits(
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 100)),
  ),
  'total_sleep_accumulates': _limits(
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 100)),
  ),
  'total_sleep_charges_the_cap': _policy(
    const OsPolicy(sleepSystemMax: Duration(milliseconds: 50)),
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 120)),
  ),
  'total_sleep_uncapped': _policy(
    const OsPolicy(sleepSystemMax: uncappedSleep),
    const ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
  ),
  'total_sleep_sub_micro': _limits(
    const ResourceLimits(maxTotalSleep: Duration(microseconds: 1)),
  ),
  'total_sleep_uncapped_huge': _policy(
    const OsPolicy(sleepSystemMax: uncappedSleep),
    const ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
  ),
  'total_sleep_uncatchable': _limits(
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 10)),
  ),
  'recursion_limit': _limits(const ResourceLimits(maxRecursionDepth: 20)),
  'suspensions_exceeded': _limits(const ResourceLimits(maxSuspensions: 2)),
  'suspensions_uncatchable': _limits(const ResourceLimits(maxSuspensions: 2)),
  'suspensions_zero': _limits(const ResourceLimits(maxSuspensions: 0)),
  'suspensions_zero_unused': _limits(const ResourceLimits(maxSuspensions: 0)),
  'suspensions_zero_name_lookup': _limits(
    const ResourceLimits(maxSuspensions: 0),
  ),
  'suspensions_name_lookup': _limits(const ResourceLimits(maxSuspensions: 1)),
  'suspensions_default': const SessionConfig(),
  'suspensions_before_sleep_limit': _limits(
    const ResourceLimits(
      maxSuspensions: 0,
      maxTotalSleep: Duration(milliseconds: 10),
    ),
  ),
  'suspensions_asyncio_sleep_zero': _limits(
    const ResourceLimits(maxSuspensions: 1),
  ),
};

/// The Dart form of each oracle sequence's checkout, by id.
final Map<String, SessionConfig> sequenceCases = {
  'suspensions_per_checkout': _limits(const ResourceLimits(maxSuspensions: 2)),
  'total_sleep_per_checkout': _limits(
    const ResourceLimits(maxTotalSleep: Duration(milliseconds: 50)),
  ),
};

/// Cases whose outcome is recorded apart from upstream's, with the reason:
/// the kind still matches, and the message carries upstream's text.
const Map<String, String> configDivergences = {};

/// Upstream's error kinds for a refused setting, all an [ArgumentError].
const List<String> _argumentKinds = [
  'ValueError: ',
  'OverflowError: ',
  'TypeError: ',
  'UnicodeEncodeError: ',
];

/// The outcome core reaches for [config] and [code], in the oracle's form.
Future<String> _outcome(
  Monty pool,
  SessionConfig config,
  String? code,
) async {
  final MontySession session;
  try {
    session = await pool.checkoutWith(config);
    // The refusal is the outcome under test.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    return 'ArgumentError: ${e.message}';
  }
  try {
    if (code == null) fail('core accepted a setting upstream refuses');

    return await _fed(session, code);
  } finally {
    await session.close();
  }
}

/// The outcome of feeding [code] to [session], in the oracle's form.
Future<String> _fed(MontySession session, String code) async {
  try {
    // The snippets print nothing; what they might is kept off the console.
    final printed = StringBuffer();
    final value = await session.feedRun(
      code,
      printCallback: (_, text) => printed.write(text),
    );

    return 'value: ${(value as MontyString).value}';
  } on MontyTypingError catch (e) {
    // Upstream's str() and display() are the same rendering, and its
    // exception() is TypeError('').
    expect('$e', e.display());
    expect(
      e.exception,
      const MontyExceptionValue(excType: 'TypeError', message: ''),
    );

    return 'MontyTypingError: ${e.display()}';
  } on MontyRuntimeError catch (e) {
    return "MontyRuntimeError: ${e.display('type-msg')}";
  }
}

/// The tests, each case on a pool from [start], closed at its end.
void configOracleTests(String label, Future<Monty> Function() start) {
  test('every oracle case has a Dart form ($label)', () {
    expect(configCases.keys.toSet(), configOracle.keys.toSet());
    // The floor: a regeneration that lost cases must not pass as green.
    expect(configOracle.length, greaterThanOrEqualTo(84));
  });

  for (final MapEntry(key: id, value: (:code, :outcome))
      in configOracle.entries) {
    test('settings $id match upstream ($label)', () async {
      final pool = await start();
      try {
        final actual = await _outcome(pool, configCases[id]!, code);
        final kind = _argumentKinds.where(outcome.startsWith).firstOrNull;
        if (kind == null) {
          expect(actual, outcome);
        } else if (configDivergences.containsKey(id)) {
          expect(actual, startsWith('ArgumentError: '));
          expect(actual, contains(outcome.substring(kind.length)));
        } else {
          expect(actual, 'ArgumentError: ${outcome.substring(kind.length)}');
        }
      } finally {
        await pool.close();
      }
    });
  }

  test('every oracle sequence has a Dart form ($label)', () {
    expect(sequenceCases.keys.toSet(), configSequences.keys.toSet());
    expect(configSequences.length, greaterThanOrEqualTo(2));
  });

  for (final MapEntry(key: id, value: feeds) in configSequences.entries) {
    test('sequence $id matches upstream, feed by feed ($label)', () async {
      final pool = await start();
      try {
        final session = await pool.checkoutWith(sequenceCases[id]!);
        try {
          final actual = [
            for (final (:code, outcome: _) in feeds) await _fed(session, code),
          ];
          expect(actual, [for (final (code: _, :outcome) in feeds) outcome]);
        } finally {
          await session.close();
        }
      } finally {
        await pool.close();
      }
    });
  }

  test('a local DateTime freezes the clock in its own zone ($label)', () async {
    // Upstream's aware datetime implies its zone; a local DateTime's zone is
    // the platform's, so the expectation is computed from it, not recorded.
    final local = DateTime(2020, 7, 2, 3, 4, 5, 678);
    final offset = local.timeZoneOffset.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    final wall =
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.678000';
    final pool = await start();
    try {
      final session = await pool.checkoutWith(
        SessionConfig(osPolicy: OsPolicy(fixedDatetime: local)),
      );
      try {
        final printed = StringBuffer();
        final value = await session.feedRun(
          'import datetime, time\n'
          'repr((str(datetime.datetime.now()), time.tzname, time.timezone))',
          printCallback: (_, text) => printed.write(text),
        );
        final name = offset == 0 && local.timeZoneName == 'UTC'
            ? 'UTC'
            : local.timeZoneName;
        expect(
          (value as MontyString).value,
          // On dart2js -0 would print as -0.0; Python's is 0.
          "('$wall', ('$name', '$name'), ${offset == 0 ? 0 : -offset})",
        );
      } finally {
        await session.close();
      }
    } finally {
      await pool.close();
    }
  });
}
