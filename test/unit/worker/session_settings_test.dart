// The session settings (lib/src/worker/resource_limits.dart, os_policy.dart
// and the SessionConfig checks in proto_session.dart): upstream's
// refusals with upstream's text, checked against the oracle's recorded
// outcomes; the Configure encoding of every field; Rust's Duration format.
// No worker runs (the same cases run against real workers in
// _config_cases.dart). Pure Dart: vm, dart2js and dart2wasm.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/tz_names.g.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_config_cases.dart';
import '_config_oracle.g.dart';
import '_scripted_channel.dart';
import '_spec_proto_support.dart';

/// The `Configure` [config] encodes to, as the worker receives it.
Future<pb.Configure> _configure(SessionConfig config) async {
  final ch = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
  ]);
  await ProtoSession.open(ch, config);

  return pb.Configure.fromBuffer(
    onlyItem(ch.requests).configure.writeToBuffer(),
  );
}

Matcher _refused(String message) => throwsA(
  isA<ArgumentError>().having((e) => e.message, 'message', message),
);

pb.OsPolicy _policy(OsPolicy policy) => policy.toProto();

ResourceLimits _limitsVariant([int changed = -1]) => ResourceLimits(
  maxFeedDuration: Duration(seconds: changed == 0 ? 8 : 1),
  maxTurnDuration: Duration(seconds: changed == 1 ? 8 : 2),
  maxMemory: changed == 2 ? 8 : 3,
  gcInterval: changed == 3 ? 8 : 4,
  maxRecursionDepth: changed == 4 ? 8 : 5,
  maxSuspensions: changed == 5 ? 8 : 6,
  maxTotalSleep: Duration(seconds: changed == 6 ? 8 : 7),
);

OsPolicy _policyVariant([int field = -1]) => OsPolicy(
  datetime: field == 0 ? 'call_host' : 'system',
  fixedDatetime: DateTime.utc(field == 1 ? 2021 : 2020),
  timezone: field == 2 ? 'Europe/London' : 'utc',
  fixedTimezone: TimeZone(field == 3 ? 1 : 0),
  sleep: field == 4 ? 'zero' : 'system',
  sleepSystemMax: Duration(seconds: field == 5 ? 2 : 1),
  processTime: field == 6 ? 'elapsed' : 'zero',
  randomStart: field == 7 ? 'call_host' : 'system',
  randomSeed: RandomSeed.string(field == 8 ? 'b' : 'a'),
);

TimeZone _zoneOf(int offset, String name) => TimeZone(offset, name: name);

void main() {
  group("upstream's refusals, as the oracle recorded them", () {
    for (final MapEntry(key: id, value: (:code, :outcome))
        in configOracle.entries) {
      // Accepted cases, and one only the worker can refuse.
      if (code != null || configDivergences.containsKey(id)) continue;
      test(id, () {
        final text = outcome.substring(outcome.indexOf(': ') + 2);
        expect(configCases[id]!.validate, _refused(text));
      });
    }
  });

  group('refusals of the Dart form only', () {
    test('both forms of one field', () {
      for (final policy in [
        OsPolicy(datetime: 'system', fixedDatetime: DateTime.utc(2020)),
        const OsPolicy(timezone: 'utc', fixedTimezone: TimeZone(0)),
        const OsPolicy(
          randomStart: 'system',
          randomSeed: RandomSeed.string(''),
        ),
      ]) {
        expect(policy.validate, throwsArgumentError);
      }
    });

    test('the limits of the ranges are accepted', () {
      const SessionConfig(
        assertMessageAnnotations: 0xffffffff,
        printFlushInterval: Duration.zero,
        limits: ResourceLimits(
          maxMemory: 0,
          gcInterval: 0,
          maxRecursionDepth: 0,
          maxSuspensions: 0,
          maxFeedDuration: Duration.zero,
          maxTurnDuration: Duration.zero,
          maxTotalSleep: Duration.zero,
        ),
        osPolicy: OsPolicy(
          fixedTimezone: TimeZone(-86399),
          sleepSystemMax: Duration.zero,
        ),
      ).validate();
      const TimeZone(86399).validate();
      // 0 is upstream's False, which this int? spells 0.
      const SessionConfig(assertMessageAnnotations: 0).validate();
    });

    test('sleepSystemMax with an explicit system sleep', () {
      const OsPolicy(
        sleep: 'system',
        sleepSystemMax: Duration(seconds: 1),
      ).validate();
    });
  });

  group('typeCheckFormat', () {
    test('ASCII case is ignored; json-lines is jsonlines', () {
      expect(
        parseTypeCheckFormat('Full'),
        pb.TypeCheckFormat.TYPE_CHECK_FORMAT_FULL,
      );
      expect(
        parseTypeCheckFormat('JSON-LINES'),
        pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES,
      );
      expect(
        parseTypeCheckFormat('jsonlines'),
        pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES,
      );
    });

    test('only ASCII letters fold', () {
      // U+0130 lowercases to i plus a combining dot outside ASCII rules.
      expect(() => parseTypeCheckFormat('GİTHUB'), throwsArgumentError);
    });
  });

  group('ResourceLimits on the wire', () {
    test('each limit, and the two that cannot be off', () {
      final limits = const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 1500),
        maxTurnDuration: Duration(microseconds: 7),
        maxMemory: 1 << 40,
        gcInterval: 10,
        maxTotalSleep: Duration(seconds: 3),
      ).toProto();
      expect(limits.maxFeedDurationMicros, Int64(1500000));
      expect(limits.maxTurnDurationMicros, Int64(7));
      expect(limits.maxMemoryBytes, Int64(1 << 40));
      expect(limits.gcInterval, Int64(10));
      expect(limits.maxTotalSleepMicros, Int64(3000000));
      expect(limits.maxRecursionDepth, Int64(1000));
      expect(limits.maxSuspensions, Int64(1000));
      final set = const ResourceLimits(
        maxRecursionDepth: 5,
        maxSuspensions: 0,
      ).toProto();
      expect(set.maxRecursionDepth, Int64(5));
      expect(set.maxSuspensions, Int64.ZERO);
      expect(set.hasMaxMemoryBytes(), isFalse);
      expect(set.hasMaxTotalSleepMicros(), isFalse);
    });
  });

  group('OsPolicy on the wire', () {
    test('every arm set, at upstream defaults', () {
      final policy = _policy(const OsPolicy());
      expect(policy.hasSystem(), isTrue);
      expect(policy.timezone.hasUtc(), isTrue);
      expect(policy.sleep.system.maxMicros, Int64(10000000));
      expect(policy.hasRandomSystem(), isTrue);
      expect(policy.hasZero(), isTrue);
    });

    test('each mode', () {
      final policy = _policy(
        const OsPolicy(
          datetime: 'call_host',
          timezone: 'Europe/London',
          sleep: 'call_host',
          processTime: 'elapsed',
          randomStart: 'call_host',
        ),
      );
      expect(policy.hasCallHost(), isTrue);
      expect(policy.timezone.named, 'Europe/London');
      expect(policy.sleep.hasCallHost(), isTrue);
      expect(policy.hasElapsed(), isTrue);
      expect(policy.hasRandomCallHost(), isTrue);
      expect(_policy(const OsPolicy(sleep: 'zero')).sleep.hasZero(), isTrue);
      expect(
        _policy(const OsPolicy(timezone: 'utc')).timezone.hasUtc(),
        isTrue,
      );
    });

    test('a fixed zone; offset 0 named UTC is the utc arm', () {
      final fixed = _policy(
        const OsPolicy(fixedTimezone: TimeZone(-12600, name: 'N')),
      ).timezone.fixed;
      expect(fixed.offsetSeconds, -12600);
      expect(fixed.name, 'N');
      expect(
        _policy(
          const OsPolicy(fixedTimezone: TimeZone(-1)),
        ).timezone.fixed.hasName(),
        isFalse,
      );
      expect(
        _policy(
          const OsPolicy(fixedTimezone: TimeZone(0, name: 'UTC')),
        ).timezone.hasUtc(),
        isTrue,
      );
    });

    test('a frozen instant: seconds and microseconds, before 1970 too', () {
      final after = _policy(
        OsPolicy(fixedDatetime: DateTime.utc(2020, 7, 2, 3, 4, 5, 678)),
      ).fixed;
      expect(after.unixSeconds, Int64(1593659045));
      expect(after.microsecond, 678000);
      final before = _policy(
        OsPolicy(fixedDatetime: DateTime.utc(1969, 12, 31, 23, 59, 59, 250)),
      ).fixed;
      expect(before.unixSeconds, Int64(-1));
      expect(before.microsecond, 250000);
    });

    test('a frozen instant far from 1970 keeps its microseconds', () {
      // Past 2^53 microseconds since the epoch, which dart2js cannot hold.
      final far = _policy(
        OsPolicy(fixedDatetime: DateTime.utc(5000, 1, 1, 0, 0, 0, 1)),
      ).fixed;
      expect(far.unixSeconds, Int64(95617584000));
      expect(far.microsecond, 1000);
    });

    test("a local DateTime implies its own zone, whatever the host's", () {
      // A host in UTC cannot tell a local instant's zone from the default,
      // so the derivation is checked on a stand-in local DateTime too.
      final instant = _LocalInstant(DateTime.utc(2020, 7, 2, 1, 4, 5, 678));
      final policy = _policy(OsPolicy(fixedDatetime: instant));
      final zone = policy.timezone.fixed;
      expect(zone.offsetSeconds, 7200);
      expect(zone.name, 'X');
      expect(policy.fixed.unixSeconds, Int64(1593651845));
      expect(policy.fixed.microsecond, 678000);
    });

    test('the zone a frozen instant implies, unless one is given', () {
      final utc = _policy(OsPolicy(fixedDatetime: DateTime.utc(2020)));
      expect(utc.timezone.hasUtc(), isTrue);
      final local = DateTime(2020, 7, 2);
      final implied = _policy(OsPolicy(fixedDatetime: local)).timezone;
      final offset = local.timeZoneOffset.inSeconds;
      if (offset == 0 && local.timeZoneName == 'UTC') {
        expect(implied.hasUtc(), isTrue);
      } else {
        expect(implied.fixed.offsetSeconds, offset);
        expect(implied.fixed.name, local.timeZoneName);
      }
      expect(
        _policy(
          OsPolicy(fixedDatetime: local, timezone: 'Asia/Tokyo'),
        ).timezone.named,
        'Asia/Tokyo',
      );
      expect(
        _policy(
          OsPolicy(fixedDatetime: local, fixedTimezone: const TimeZone(60)),
        ).timezone.fixed.offsetSeconds,
        60,
      );
      expect(
        _policy(
          OsPolicy(fixedDatetime: local, timezone: 'utc'),
        ).timezone.hasUtc(),
        isTrue,
      );
    });

    test('the uncapped spelling is u64::MAX on the wire', () {
      final bytes = _policy(
        const OsPolicy(sleepSystemMax: uncappedSleep),
      ).sleep.system.writeToBuffer();
      expect(
        pb.SystemSleep.fromBuffer(bytes).maxMicros.toStringUnsigned(),
        '18446744073709551615',
      );
      expect(
        _policy(
          const OsPolicy(
            sleepSystemMax: Duration(microseconds: 9007199254740990),
          ),
        ).sleep.system.maxMicros,
        Int64(9007199254740990),
      );
    });

    test('the sleep the parent waits: the system cap, else 10 s', () {
      expect(
        const OsPolicy(sleepSystemMax: Duration(seconds: 2)).systemSleepMax,
        const Duration(seconds: 2),
      );
      expect(
        const OsPolicy(sleep: 'zero').systemSleepMax,
        const Duration(seconds: 10),
      );
      expect(
        const OsPolicy(sleep: 'call_host').systemSleepMax,
        const Duration(seconds: 10),
      );
      expect(const SessionConfig().systemSleepMax, const Duration(seconds: 10));
    });
  });

  // The worker's bundled tz database (jiff-tzdb, tool/generate_tz_names.py),
  // which decides where the host has no zoneinfo directory: the web.
  group('the bundled zone names', () {
    test('every listed name, in any ASCII case; nothing else', () {
      for (final name in tzNames) {
        expect(isBundledZone(name), isTrue, reason: name);
        expect(isBundledZone(name.toUpperCase()), isTrue, reason: name);
      }
      for (final name in ['posixrules', 'Etc/Unknown', 'zone.tab', 'Q/Z']) {
        expect(isBundledZone(name), isFalse, reason: name);
      }
    });

    // jiff's `special_time_zone`, before any database.
    test('UTC in any ASCII case is known; Etc/Unknown is not', () {
      for (final name in ['UTC', 'utc', 'uTc']) {
        expect(isKnownZone(name), isTrue, reason: name);
      }
      for (final name in ['Etc/Unknown', 'etc/UNKNOWN']) {
        expect(isKnownZone(name), isFalse, reason: name);
      }
    });
  });

  group('RandomSeed', () {
    test('each kind keeps its arm, on every compiler', () {
      // On dart2js 1.0 and 1 are one value; the constructor says which.
      expect(const RandomSeed.float(1).toProto().hasFloat(), isTrue);
      expect(RandomSeed.integer(BigInt.one).toProto().int_1, [1]);
      expect(const RandomSeed.string('a').toProto().str, 'a');
      expect(
        RandomSeed.bytes(Uint8List.fromList([0, 255])).toProto().bytes,
        [0, 255],
      );
    });

    test("an integer is num-bigint's to_signed_bytes_le", () {
      final cases = {
        0: [0],
        1: [1],
        127: [127],
        128: [128, 0],
        255: [255, 0],
        256: [0, 1],
        -1: [255],
        -128: [128],
        -129: [127, 255],
        -256: [0, 255],
      };
      for (final MapEntry(key: n, value: bytes) in cases.entries) {
        expect(signedBytesLe(BigInt.from(n)), bytes, reason: '$n');
      }
      expect(signedBytesLe(BigInt.two.pow(70)), [...List.filled(8, 0), 64]);
      expect(signedBytesLe(-BigInt.two.pow(70)), [
        ...List.filled(8, 0),
        192,
      ]);
    });

    test('a bytes seed is a copy of the bytes it was given', () {
      final source = Uint8List.fromList([1, 2]);
      final seed = RandomSeed.bytes(source);
      final hash = seed.hashCode;
      source[0] = 9;
      expect(seed.toProto().bytes, [1, 2]);
      expect(seed.hashCode, hash);
      expect(seed, RandomSeed.bytes(Uint8List.fromList([1, 2])));
    });

    // Upstream's RandomSeed is a TypedDict: dict equality, so an int and a
    // float seed of equal value are equal (pydantic_monty __init__.py:188).
    test('an integer and a float seed of equal value are equal', () {
      for (final (n, f) in [
        (BigInt.one, 1.0),
        (BigInt.zero, -0.0),
        (-BigInt.two.pow(70), -1180591620717411303424.0),
      ]) {
        final integer = RandomSeed.integer(n);
        final float = RandomSeed.float(f);
        expect(integer, float);
        expect(float, integer);
        expect(integer.hashCode, float.hashCode);
        // The wire still carries the kind the caller chose.
        expect(integer.toProto().hasInt_1(), isTrue);
        expect(float.toProto().hasFloat(), isTrue);
      }
      for (final (n, f) in [
        (BigInt.one, 1.5),
        (BigInt.two.pow(53) + BigInt.one, 9007199254740992.0),
        (BigInt.zero, double.nan),
      ]) {
        expect(RandomSeed.integer(n) == RandomSeed.float(f), isFalse);
      }
    });

    test('== and hashCode: by kind and value', () {
      RandomSeed bytesOf(List<int> b) =>
          RandomSeed.bytes(Uint8List.fromList(b));
      const float = RandomSeed.float(1);
      final one = RandomSeed.integer(BigInt.one);
      final otherOne = RandomSeed.integer(BigInt.one);
      expect(one == const RandomSeed.float(2), isFalse);
      expect(one, otherOne);
      expect(one.hashCode, otherOne.hashCode);
      final bytes = bytesOf([1]);
      final otherBytes = bytesOf([1]);
      expect(bytes, otherBytes);
      expect(bytes.hashCode, otherBytes.hashCode);
      expect(bytes == bytesOf([2]), isFalse);
      expect(const RandomSeed.string('1') == float, isFalse);
      final [text, sameText] = [
        for (var i = 0; i < 2; i++) RandomSeed.string(String.fromCharCode(97)),
      ];
      expect(text, sameText);
      expect(text.hashCode, sameText.hashCode);
    });
  });

  group('== and hashCode', () {
    test('equal settings are equal, any field apart they are not', () {
      const a = OsPolicy(
        sleep: 'zero',
        fixedTimezone: TimeZone(1, name: 'n'),
      );
      const b = OsPolicy(
        sleep: 'zero',
        fixedTimezone: TimeZone(1, name: 'n'),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const OsPolicy(sleep: 'zero')));
      const l = ResourceLimits(
        maxMemory: 1,
        maxTotalSleep: Duration(seconds: 1),
      );
      expect(
        l,
        const ResourceLimits(maxMemory: 1, maxTotalSleep: Duration(seconds: 1)),
      );
      expect(
        l.hashCode,
        const ResourceLimits(
          maxMemory: 1,
          maxTotalSleep: Duration(seconds: 1),
        ).hashCode,
      );
      expect(l, isNot(const ResourceLimits(maxMemory: 1)));
      expect(const TimeZone(1), isNot(const TimeZone(1, name: 'n')));
    });
  });

  group("Rust's Duration Debug format", () {
    test('the largest unit with a whole part; trailing zeros dropped', () {
      final cases = {
        const Duration(milliseconds: 150): '150ms',
        const Duration(milliseconds: 1500): '1.5s',
        const Duration(seconds: 1): '1s',
        const Duration(milliseconds: 5500): '5.5s',
        const Duration(microseconds: 200035917): '200.035917s',
        const Duration(microseconds: 200917): '200.917ms',
        const Duration(milliseconds: 10): '10ms',
        const Duration(microseconds: 1): '1µs',
        const Duration(microseconds: 1500): '1.5ms',
        const Duration(microseconds: 1000001): '1.000001s',
        Duration.zero: '0ns',
        const Duration(minutes: 2): '120s',
      };
      for (final MapEntry(key: d, value: text) in cases.entries) {
        expect(rustDuration(d), text, reason: '$d');
      }
    });
  });

  group("Rust's Duration from float seconds, in nanoseconds", () {
    test('exact to the nanosecond, rounded to the nearest', () {
      final cases = {
        0.15: '150000000',
        0.0000014: '1400',
        1.5: '1500000000',
        9.1e9: '9100000000000000000',
        0.0: '0',
        // Half a nanosecond rounds to even: 0.5 ns is below one ulp of
        // 1e-9 here, so the double is not a tie; 2.5e-9 is close to one.
        1e-9: '1',
      };
      for (final MapEntry(key: seconds, value: nanos) in cases.entries) {
        expect('${nanosFromSeconds(seconds)}', nanos, reason: '$seconds');
      }
    });

    test('negative, NaN, infinite or past u64::MAX seconds: none', () {
      for (final seconds in [
        -1.0,
        -1e-12,
        double.nan,
        double.infinity,
        1.9e19,
      ]) {
        expect(nanosFromSeconds(seconds), isNull, reason: '$seconds');
      }
    });

    test("the Debug format from nanoseconds, Duration::MAX's included", () {
      expect(rustDurationNanos(BigInt.from(1400)), '1.4µs');
      expect(rustDurationNanos(BigInt.from(999)), '999ns');
      expect(
        rustDurationNanos(BigInt.parse('9100000000000000000')),
        '9100000000s',
      );
      expect(
        rustDurationNanos(durationMaxNanos),
        '18446744073709551615.999999999s',
      );
    });
  });

  group('limits past u64::MAX', () {
    test('a duration dart2js holds past 2^63 or 2^64 µs saturates', () {
      // Only dart2js has such a Duration; elsewhere this is 2^63 - 1 µs.
      final huge = math.pow(2, 64).toInt();
      if (huge.toDouble() < 18446744073709551616.0) return;
      final past64 = Duration(microseconds: huge);
      final past63 = Duration(microseconds: math.pow(2, 63).toInt());
      final limits = ResourceLimits(
        maxFeedDuration: past64,
        maxTurnDuration: past63,
        maxTotalSleep: past64,
      )..validate();
      final wire = limits.toProto();
      expect(
        wire.maxFeedDurationMicros.toStringUnsigned(),
        '18446744073709551615',
      );
      expect(
        wire.maxTurnDurationMicros.toStringUnsigned(),
        '9223372036854775808',
      );
      expect(
        wire.maxTotalSleepMicros.toStringUnsigned(),
        '18446744073709551615',
      );
      expect(
        _policy(
          OsPolicy(sleepSystemMax: past64),
        ).sleep.system.maxMicros.toStringUnsigned(),
        '18446744073709551615',
      );
      // Past u64::MAX seconds, Rust has no Duration at all.
      expect(
        ResourceLimits(
          maxFeedDuration: Duration(microseconds: huge * huge),
        ).validate,
        _refused(
          'cannot convert float seconds to Duration: value is either too '
          'big or NaN',
        ),
      );
    });

    test('an int dart2js holds past 2^64 is refused, as upstream', () {
      // Only dart2js has such an int; elsewhere this is 2^63 - 1.
      final huge = math.pow(2, 64).toInt();
      if (huge.toDouble() < 18446744073709551616.0) return;
      expect(
        ResourceLimits(maxMemory: huge).validate,
        _refused('int too big to convert'),
      );
    });
  });

  group('printFlushIntervalMs', () {
    test("upstream's flush_interval_ms", () {
      expect(printFlushIntervalMs(Duration.zero), 0);
      expect(printFlushIntervalMs(const Duration(microseconds: 500)), 1);
      expect(printFlushIntervalMs(const Duration(milliseconds: 5)), 5);
      expect(
        printFlushIntervalMs(const Duration(days: 60)),
        0xffffffff,
      );
    });
  });

  test('Configure carries the settings', () async {
    final configure = await _configure(
      const SessionConfig(
        limits: ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
        osPolicy: OsPolicy(processTime: 'elapsed'),
        printFlushInterval: Duration(microseconds: 10),
        typeCheck: true,
        typeCheckFormat: 'GitHub',
      ),
    );
    expect(configure.limits.maxTotalSleepMicros, Int64(1000000));
    expect(configure.osPolicy.hasElapsed(), isTrue);
    expect(configure.printFlushIntervalMs, 1);
    expect(
      configure.typeCheckFormat,
      pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB,
    );
  });

  group('ResourceLimits values and checkout', () {
    test('all seven omitted fields store null', () {
      const limits = ResourceLimits();
      expect([
        limits.maxFeedDuration,
        limits.maxTurnDuration,
        limits.maxMemory,
        limits.gcInterval,
        limits.maxRecursionDepth,
        limits.maxSuspensions,
        limits.maxTotalSleep,
      ], List<Object?>.filled(7, null));
    });

    test(
      'equality and hash include every stored field',
      () {
        final a = _limitsVariant();
        final b = _limitsVariant();
        expect(identical(a, b), isFalse);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(
          a.hashCode,
          Object.hash(
            const Duration(seconds: 1),
            const Duration(seconds: 2),
            3,
            4,
            5,
            6,
            const Duration(seconds: 7),
          ),
        );
        for (var field = 0; field < 7; field++) {
          final different = _limitsVariant(field);
          expect(a == different, isFalse, reason: 'field $field');
          expect(different == a, isFalse, reason: 'field $field');
          expect(different.hashCode, isNot(a.hashCode), reason: 'field $field');
        }
      },
    );

    test(
      'null limits are omitted and mandatory defaults remain',
      () async {
        final (_, channel) = await protoSession([]);
        final limits = channel.requests.singleOrNull?.configure.limits;
        expect(limits?.hasMaxFeedDurationMicros(), isFalse);
        expect(limits?.hasMaxTurnDurationMicros(), isFalse);
        expect(limits?.hasMaxMemoryBytes(), isFalse);
        expect(limits?.hasMaxTotalSleepMicros(), isFalse);
        expect(limits?.maxRecursionDepth.toInt(), 1000);
        expect(limits?.maxSuspensions.toInt(), 1000);
      },
    );
  });

  group('OsPolicy and TimeZone values, offsets at checkout', () {
    test('equality and hashing use all configured fields', () {
      // Equality is defined even for values checkout would reject.
      final a = _policyVariant();
      final b = _policyVariant();
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      for (var field = 0; field < 9; field++) {
        final changed = _policyVariant(field);
        expect(a == changed, isFalse, reason: 'field $field');
        expect(changed == a, isFalse, reason: 'field $field');
        expect(a.hashCode, isNot(changed.hashCode), reason: 'field $field');
      }
      expect(const OsPolicy(), isNot(const OsPolicy(datetime: 'system')));
    });

    test('distinct zones compare by offset and name', () {
      final a = _zoneOf(3600, 'X');
      final b = _zoneOf(3600, 'X');
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      for (final different in [
        const TimeZone(3601, name: 'X'),
        const TimeZone(3600, name: 'Y'),
        const TimeZone(3600),
        const TimeZone(3600, name: ''),
      ]) {
        expect(a == different, isFalse);
        expect(a.hashCode, isNot(different.hashCode));
      }
      expect(const TimeZone(0), isNot(const TimeZone(0, name: '')));
    });

    test('invalid offsets send no Configure', () async {
      final channel = ScriptedChannel([]);
      var spawns = 0;
      final pool = await startMonty(
        const PoolOptions(minProcesses: 0, maxProcesses: 1),
        open: () {
          spawns++;

          return PendingSpawn((_) async => channel);
        },
      );
      addTearDown(pool.close);
      for (final offset in [-86400, 86400]) {
        await expectLater(
          pool.checkout(osPolicy: OsPolicy(fixedTimezone: TimeZone(offset))),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'timezone offset_seconds must be within -86399..=86399, '
                  'got $offset',
            ),
          ),
        );
        expect(spawns, 0);
        expect(channel.requests, isEmpty);
      }
    });
  });
}

/// A local DateTime in a zone 2 hours east of UTC named `X`, on any host.
final class _LocalInstant implements DateTime {
  const _LocalInstant(this._utc);

  final DateTime _utc;

  @override
  bool get isUtc => false;

  @override
  Duration get timeZoneOffset => const Duration(hours: 2);

  @override
  String get timeZoneName => 'X';

  @override
  int get millisecondsSinceEpoch => _utc.millisecondsSinceEpoch;

  @override
  int get microsecond => 0;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
