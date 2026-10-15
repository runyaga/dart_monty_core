/// Upstream's `OSPolicy`, `TimeZone` and `RandomSeed`, their validation
/// and their `Configure` encoding.
///
/// Upstream's are TypedDicts (`pydantic_monty/__init__.py`); here each is a
/// small immutable class. Literals are `String`s, and a field that is a mode
/// or a value is two parameters (the mode, and a typed value form). A value
/// upstream's argument parsing refuses is an [ArgumentError] with upstream's
/// message, raised by `OsPolicyInternal.validate` at checkout.
///
/// Internal until the cutover exports them; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart'
    show surrogateEncodeError;
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/tz_names.g.dart';
import 'package:dart_monty_core/src/worker/zone_database.dart';
import 'package:fixnum/fixnum.dart';
import 'package:meta/meta.dart';

/// Upstream's `OSPolicy`: the clock, zone, sleep, process clock and initial
/// randomness a session gets, and which of them it asks the host for.
///
/// Each null keeps upstream's default: the system clock in UTC, system
/// sleeps capped at 10 s, a zero process clock, and OS entropy.
@immutable
final class OsPolicy {
  /// The policy; see each field. Setting both forms of one field is an
  /// [ArgumentError] at checkout.
  const OsPolicy({
    this.datetime,
    this.fixedDatetime,
    this.timezone,
    this.fixedTimezone,
    this.sleep,
    this.sleepSystemMax,
    this.processTime,
    this.randomStart,
    this.randomSeed,
  });

  /// Where `datetime.now()`, `date.today()` and `time.time()` read the
  /// instant: `'system'` (the default) or `'call_host'`. [fixedDatetime] is
  /// the third form.
  final String? datetime;

  /// One frozen instant, to the microsecond. Unless [timezone] or
  /// [fixedTimezone] says otherwise, it also sets the sandbox's zone: UTC
  /// for a UTC [DateTime], else the [DateTime]'s offset and zone name, which
  /// are the platform's.
  final DateTime? fixedDatetime;

  /// The sandbox's zone: `'utc'` or an IANA name such as `'Europe/London'`,
  /// matched ignoring ASCII case against the worker's zone database (the
  /// host's zoneinfo on native, else the copy every worker holds).
  /// [fixedTimezone] is the third form.
  final String? timezone;

  /// A fixed offset as the sandbox's zone.
  final TimeZone? fixedTimezone;

  /// What `time.sleep()` does: `'system'` (the default; the host waits),
  /// `'call_host'` (an OS call) or `'zero'` (no wait).
  final String? sleep;

  /// The longest one system sleep waits; longer ones are cut to it. Null is
  /// 10 s. `Duration(microseconds: 9007199254740991)` (2^53 - 1, the largest
  /// exact on every compiler) is uncapped, upstream's `float('inf')`. Only
  /// with [sleep] `'system'`.
  final Duration? sleepSystemMax;

  /// What `time.process_time()` reports: `'zero'` (the default) or
  /// `'elapsed'`.
  final String? processTime;

  /// Where an unseeded `random` gets its first state: `'system'` (the
  /// default) or `'call_host'`. [randomSeed] is the third form.
  final String? randomStart;

  /// Seeds `random` as `random.seed(seed)` would.
  final RandomSeed? randomSeed;

  @override
  bool operator ==(Object other) =>
      other is OsPolicy &&
      other.datetime == datetime &&
      other.fixedDatetime == fixedDatetime &&
      other.timezone == timezone &&
      other.fixedTimezone == fixedTimezone &&
      other.sleep == sleep &&
      other.sleepSystemMax == sleepSystemMax &&
      other.processTime == processTime &&
      other.randomStart == randomStart &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(
    datetime,
    fixedDatetime,
    timezone,
    fixedTimezone,
    sleep,
    sleepSystemMax,
    processTime,
    randomStart,
    randomSeed,
  );

  /// Throws [ArgumentError] for a value upstream refuses, with upstream's
  /// message, or for both forms of one field. An IANA zone name is checked
  /// here, before any worker is taken, as upstream checks it while parsing
  /// the checkout's arguments.
  void _validate() {
    _bothForms(datetime, fixedDatetime, 'datetime', 'fixedDatetime');
    _bothForms(timezone, fixedTimezone, 'timezone', 'fixedTimezone');
    _bothForms(randomStart, randomSeed, 'randomStart', 'randomSeed');
    _oneOf(
      datetime,
      'datetime',
      const {'system', 'call_host'},
      "datetime must be 'system', 'call_host' or a datetime.datetime, "
          "got '$datetime'",
    );
    _validateZoneName(timezone);
    fixedTimezone?.validate();
    randomSeed?.validate();
    _oneOf(
      sleep,
      'sleep',
      const {'system', 'call_host', 'zero'},
      "sleep must be 'system', 'call_host' or 'zero', got '$sleep'",
    );
    _oneOf(
      processTime,
      'processTime',
      const {'zero', 'elapsed'},
      "process_time must be 'zero' or 'elapsed', got '$processTime'",
    );
    _oneOf(
      randomStart,
      'randomStart',
      const {'system', 'call_host'},
      "random_start must be 'system', 'call_host' or "
          "{'seed': int | float | str | bytes}, got '$randomStart'",
    );
    _validateSleepMax();
  }

  /// The longest one system sleep is charged, in nanoseconds: the
  /// system-sleep maximum, or Rust's `Duration::MAX` for [uncappedSleep],
  /// as upstream's `float('inf')`.
  BigInt get _systemSleepCapNanos {
    final max = _systemSleepMax;

    return max == uncappedSleep ? durationMaxNanos : nanosOf(max);
  }

  /// The longest one system sleep waits: [sleepSystemMax] under the system
  /// mode, else upstream's 10 s (the parent's ceiling whatever the mode).
  Duration get _systemSleepMax =>
      (sleep ?? 'system') == 'system' ? sleepSystemMax ?? _sleepMax : _sleepMax;

  /// The wire form, every arm set, as upstream's encoder sends it.
  pb.OsPolicy _toProto() {
    final policy = pb.OsPolicy(
      timezone: _zone(),
      sleep: switch (sleep ?? 'system') {
        'call_host' => pb.SleepMode(callHost: pb.Unit()),
        'zero' => pb.SleepMode(zero: pb.Unit()),
        _ => pb.SleepMode(
          system: pb.SystemSleep(maxMicros: _sleepMicros(_systemSleepMax)),
        ),
      },
    );
    final instant = fixedDatetime;
    if (instant != null) {
      policy.fixed = _fixed(instant);
    } else if (datetime == 'call_host') {
      policy.callHost = pb.Unit();
    } else {
      policy.system = pb.Unit();
    }
    final seed = randomSeed;
    if (seed != null) {
      policy.seed = seed.toProto();
    } else if (randomStart == 'call_host') {
      policy.randomCallHost = pb.Unit();
    } else {
      policy.randomSystem = pb.Unit();
    }
    if (processTime == 'elapsed') {
      policy.elapsed = pb.Unit();
    } else {
      policy.zero = pb.Unit();
    }

    return policy;
  }

  /// [sleepSystemMax] must be a duration, and only with the system sleep.
  void _validateSleepMax() {
    final max = sleepSystemMax;
    if (max == null) return;
    final refusal = durationRefusal(max);
    if (refusal != null) {
      throw ArgumentError.value(
        max,
        'sleepSystemMax',
        'invalid sleep_system_max: $refusal',
      );
    }
    final mode = sleep ?? 'system';
    if (mode != 'system') {
      throw ArgumentError.value(
        max,
        'sleepSystemMax',
        "sleep_system_max only applies to sleep='system', not '$mode'",
      );
    }
  }

  /// The zone: the explicit one, else the one [fixedDatetime] implies, else
  /// UTC.
  pb.SandboxTimeZone _zone() {
    final fixed = fixedTimezone;
    if (fixed != null) return fixed._toProto();
    final named = timezone;
    if (named != null && named != 'utc') {
      return pb.SandboxTimeZone(named: named);
    }
    final instant = fixedDatetime;
    if (named == null && instant != null && !instant.isUtc) {
      return TimeZone(
        instant.timeZoneOffset.inSeconds,
        name: instant.timeZoneName,
      )._toProto();
    }

    return pb.SandboxTimeZone(utc: pb.Unit());
  }
}

/// Throws upstream's refusal of [name] as the `timezone` argument: a string
/// with no UTF-8 form, then a name that is neither `'utc'` nor one the tz
/// database resolves (monty-types `NamedZone::resolve`).
void _validateZoneName(String? name) {
  if (name == null) return;
  final unencodable = surrogateEncodeError(name);
  if (unencodable != null) {
    throw ArgumentError.value(name, 'timezone', unencodable);
  }
  if (name == 'utc' || isKnownZone(name)) return;
  throw ArgumentError.value(name, 'timezone', "unknown timezone '$name'");
}

/// Whether the worker's tz database resolves [name] to a named zone, as
/// monty-types `NamedZone::resolve` asks it: at most 100 bytes, each
/// `/`-part non-empty, not `.` or `..`, of ASCII letters, digits and
/// `._+-`, then looked up ignoring ASCII case.
///
/// The database is jiff's: the host's zoneinfo directory where a native
/// worker reads one, else the copy compiled into every worker ([tzNames]).
bool isKnownZone(String name) {
  if (name.length > 100) return false;
  for (final part in name.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') return false;
    if (!_zonePart.hasMatch(part)) return false;
  }
  // jiff's special names, whatever the database (tz/db/mod.rs
  // `special_time_zone`): `Etc/Unknown` has no IANA name, so upstream
  // refuses it.
  switch (name.toLowerCase()) {
    case 'utc':
      return true;
    case 'etc/unknown':
      return false;
  }

  return hostZoneKnown(name) ?? isBundledZone(name);
}

/// Whether the copy of the tz database every worker holds ([tzNames]) has
/// [name], ignoring ASCII case: the database where there is no host one.
@visibleForTesting
bool isBundledZone(String name) =>
    _zonesByLowerName.contains(name.toLowerCase());

final RegExp _zonePart = RegExp(r'^[A-Za-z0-9._+-]+$');

/// [tzNames] as the database matches them, ignoring ASCII case.
final Set<String> _zonesByLowerName = {
  for (final name in tzNames) name.toLowerCase(),
};

/// Upstream's `SleepMode::DEFAULT_MAX`.
const Duration _sleepMax = Duration(seconds: 10);

/// The `Duration` that spells an uncapped system sleep: 2^53 - 1
/// microseconds, exact on every compiler.
const Duration uncappedSleep = Duration(microseconds: 9007199254740991);

/// Upstream's `TimeZone`: a fixed offset from UTC, with a name if it has
/// one. Configuration, apart from the `MontyTimeZone` value.
@immutable
final class TimeZone {
  /// A zone [offsetSeconds] east of UTC, called [name].
  const TimeZone(this.offsetSeconds, {this.name});

  /// The offset east of UTC, strictly within a day.
  final int offsetSeconds;

  /// The name `%Z` and `time.tzname` report; without one, `UTC+hh:mm`.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is TimeZone &&
      other.offsetSeconds == offsetSeconds &&
      other.name == name;

  @override
  int get hashCode => Object.hash(offsetSeconds, name);

  /// Throws [ArgumentError] for what upstream's parsing refuses, in its
  /// order: an offset outside `i32` (its extraction's `OverflowError`), a
  /// name with no UTF-8 form, then an offset outside upstream's range.
  void _validate() {
    if (offsetSeconds < _minI32 || offsetSeconds > _maxI32) {
      throw ArgumentError.value(
        offsetSeconds,
        'offsetSeconds',
        'number too ${offsetSeconds < 0 ? 'small' : 'large'} to fit in '
            'target type',
      );
    }
    final zoneName = name;
    final unencodable = zoneName == null
        ? null
        : surrogateEncodeError(zoneName);
    if (unencodable != null) {
      throw ArgumentError.value(zoneName, 'name', unencodable);
    }
    if (offsetSeconds < _minOffset || offsetSeconds > _maxOffset) {
      throw ArgumentError.value(
        offsetSeconds,
        'offsetSeconds',
        'timezone offset_seconds must be within '
            '$_minOffset..=$_maxOffset, got $offsetSeconds',
      );
    }
  }

  /// Upstream's encoder sends its UTC zone, offset 0 named `UTC`, as the
  /// `utc` arm.
  pb.SandboxTimeZone _toProto() => offsetSeconds == 0 && name == 'UTC'
      ? pb.SandboxTimeZone(utc: pb.Unit())
      : pb.SandboxTimeZone(
          fixed: pb.TimeZone(offsetSeconds: offsetSeconds, name: name),
        );
}

/// Upstream's `MIN_TIMEZONE_OFFSET_SECONDS` and `MAX_...`.
const int _minOffset = -86399;
const int _maxOffset = 86399;

/// The range of the `i32` upstream extracts an offset into.
const int _minI32 = -0x80000000;
const int _maxI32 = 0x7FFFFFFF;

/// Upstream's `RandomSeed`: a `random.seed()` argument, one constructor per
/// kind, so dart2js, where `1` and `1.0` are one value, still sends the
/// kind the caller meant.
@immutable
final class RandomSeed {
  /// An integer seed.
  const RandomSeed.integer(BigInt seed) : _seed = seed;

  /// A float seed; it must be finite, which [validate] checks.
  const RandomSeed.float(double seed) : _seed = seed;

  /// A string seed.
  const RandomSeed.string(String seed) : _seed = seed;

  /// A bytes seed, a copy of [seed].
  // Not const: the copy keeps the seed immutable.
  RandomSeed.bytes(Uint8List seed)
    : _seed = Uint8List.fromList(seed).asUnmodifiableView();

  /// The seed: a [BigInt], a `double`, a [String] or a [Uint8List].
  final Object _seed;

  /// Equal as upstream's dicts are: an integer and a float seed of equal
  /// value are equal, compared exactly, as Python compares them.
  @override
  bool operator ==(Object other) =>
      other is RandomSeed &&
      switch ((_seed, other._seed)) {
        (final Uint8List a, final Uint8List b) => _bytes.equals(a, b),
        (final BigInt a, final double b) ||
        (final double b, final BigInt a) => _integral(b) == a,
        (final double a, final double b) => a == b,
        (final a, final b) => a == b,
      };

  /// An integer seed and the float equal to it hash alike.
  @override
  int get hashCode => switch (_seed) {
    final Uint8List bytes => _bytes.hash(bytes),
    final double f => Object.hash(double, _integral(f) ?? f),
    final BigInt n => Object.hash(double, n),
    final seed => Object.hash(seed.runtimeType, seed),
  };

  /// Throws [ArgumentError] for what upstream's parsing refuses, with its
  /// message: a float seed that is not finite, a string seed with no UTF-8
  /// form.
  void _validate() {
    final seed = _seed;
    if (seed is String) {
      final unencodable = surrogateEncodeError(seed);
      if (unencodable == null) return;
      throw ArgumentError.value(seed, 'randomSeed', unencodable);
    }
    if (seed is! double || seed.isFinite) return;
    // Rust's Display for a non-finite f64.
    var shown = seed.isNegative ? '-inf' : 'inf';
    if (seed.isNaN) shown = 'NaN';
    throw ArgumentError.value(
      seed,
      'randomSeed',
      'random_start seed must be finite, not $shown',
    );
  }

  /// The wire form; an integer as its two's-complement bytes.
  pb.RandomSeed _toProto() => switch (_seed) {
    final BigInt n => pb.RandomSeed(int_1: signedBytesLe(n)),
    final double f => pb.RandomSeed(float: f),
    final String s => pb.RandomSeed(str: s),
    final Uint8List b => pb.RandomSeed(bytes: b),
    _ => throw StateError('unreachable seed $_seed'),
  };
}

const ListEquality<int> _bytes = ListEquality();

/// [f] as the integer it equals, or null when it is not integral.
BigInt? _integral(double f) =>
    f.isFinite && f == f.truncateToDouble() ? BigInt.from(f) : null;

/// [n] in two's complement, little-endian, in the fewest bytes (num-bigint's
/// `to_signed_bytes_le`, which the worker decodes).
List<int> signedBytesLe(BigInt n) {
  final out = <int>[];
  final byteMask = BigInt.from(0xff);
  final minusOne = BigInt.from(-1);
  var rest = n;
  for (;;) {
    final byte = (rest & byteMask).toInt();
    rest = rest >> 8;
    out.add(byte);
    final signClear = byte & 0x80 == 0;
    if ((rest == BigInt.zero && signClear) ||
        (rest == minusOne && !signClear)) {
      return out;
    }
  }
}

void _bothForms(Object? mode, Object? value, String modeName, String name) {
  if (mode != null && value != null) {
    throw ArgumentError('$modeName and $name cannot both be set');
  }
}

void _oneOf(String? value, String name, Set<String> accepted, String text) {
  if (value != null && !accepted.contains(value)) {
    throw ArgumentError.value(value, name, text);
  }
}

/// [instant] as the wire's seconds and microsecond, from its milliseconds
/// and its sub-millisecond microseconds: exact on dart2js too, where the
/// microseconds since the epoch can pass 2^53.
pb.FixedDateTime _fixed(DateTime instant) {
  final ms = instant.millisecondsSinceEpoch;
  final rest = ms % 1000;

  return pb.FixedDateTime(
    unixSeconds: Int64((ms - rest) ~/ 1000),
    microsecond: rest * 1000 + instant.microsecond,
  );
}

/// [max] in wire microseconds; [uncappedSleep] is `u64::MAX`, which the
/// uint64 field holds as the 64-bit pattern of -1.
Int64 _sleepMicros(Duration max) =>
    max == uncappedSleep ? Int64(-1) : durationMicros(max);

/// [OsPolicy]'s internal members (pass-3 G2, #220): the public show list
/// leaves this extension out.
extension OsPolicyInternal on OsPolicy {
  /// See the private member.
  void validate() => _validate();

  /// See the private member.
  BigInt get systemSleepCapNanos => _systemSleepCapNanos;

  /// See the private member.
  Duration get systemSleepMax => _systemSleepMax;

  /// See the private member.
  pb.OsPolicy toProto() => _toProto();
}

/// [TimeZone]'s internal members (pass-3 G2, #220): the public show list
/// leaves this extension out.
extension TimeZoneInternal on TimeZone {
  /// See the private member.
  void validate() => _validate();
}

/// [RandomSeed]'s internal members (pass-3 G2, #220): the public show list
/// leaves this extension out.
extension RandomSeedInternal on RandomSeed {
  /// See the private member.
  void validate() => _validate();

  /// See the private member.
  pb.RandomSeed toProto() => _toProto();
}
