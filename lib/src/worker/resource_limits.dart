/// Upstream's `ResourceLimits`, its validation and its `Configure`
/// encoding, and the Rust `Duration` format its limit messages use.
///
/// Upstream's is a TypedDict (`pydantic_monty/__init__.py`); here it is a
/// small immutable class whose durations are [Duration]s. A value upstream's
/// argument parsing refuses is an [ArgumentError] with upstream's message,
/// raised by [ResourceLimitsInternal.validate] at checkout.
///
/// The package exports [ResourceLimits]; the rest of this library is
/// internal.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:meta/meta.dart';

/// Upstream's `ResourceLimits`: the limits one session runs under.
///
/// A null limit is off, except [maxRecursionDepth] and [maxSuspensions],
/// which cannot be turned off: null keeps upstream's default of 1000.
///
/// [maxSuspensions] and [maxTotalSleep] are counted by the parent, not
/// the interpreter, and add up over the whole checkout, every feed and
/// resume included: 1000 suspensions by default, no sleep budget unless
/// one is set.
///
/// A restored dump does not loosen them: `loadSession` and `loadSnapshot`
/// keep the receiving checkout's [maxSuspensions] and [maxTotalSleep] as
/// ceilings, which the dump's own limits only tighten, so a checkout that
/// restores a dump must set both itself, at least as loose as the dump's.
@immutable
final class ResourceLimits {
  /// The limits; see each field.
  const ResourceLimits({
    this.maxFeedDuration,
    this.maxTurnDuration,
    this.maxMemory,
    this.gcInterval,
    this.maxRecursionDepth,
    this.maxSuspensions,
    this.maxTotalSleep,
  });

  /// The longest one feed may run, its suspensions excluded (upstream
  /// `max_feed_duration_secs`).
  final Duration? maxFeedDuration;

  /// The longest one turn may run: a feed, or a resume after a suspension
  /// (upstream `max_turn_duration_secs`).
  final Duration? maxTurnDuration;

  /// The interpreter's heap limit in bytes; past it Python raises
  /// `MemoryError`, and the session survives.
  final int? maxMemory;

  /// How many allocations pass between garbage collections.
  final int? gcInterval;

  /// The interpreter's recursion limit; null keeps 1000.
  final int? maxRecursionDepth;

  /// How many host calls a session may suspend for; past it the feed is
  /// aborted with an uncatchable `RuntimeError`. Null keeps 1000.
  final int? maxSuspensions;

  /// The most the session's system sleeps may add up to; the sleep that
  /// would pass it raises an uncatchable `TimeoutError` instead of waiting
  /// (upstream `max_total_sleep_secs`).
  final Duration? maxTotalSleep;

  @override
  bool operator ==(Object other) =>
      other is ResourceLimits &&
      other.maxFeedDuration == maxFeedDuration &&
      other.maxTurnDuration == maxTurnDuration &&
      other.maxMemory == maxMemory &&
      other.gcInterval == gcInterval &&
      other.maxRecursionDepth == maxRecursionDepth &&
      other.maxSuspensions == maxSuspensions &&
      other.maxTotalSleep == maxTotalSleep;

  @override
  int get hashCode => Object.hash(
    maxFeedDuration,
    maxTurnDuration,
    maxMemory,
    gcInterval,
    maxRecursionDepth,
    maxSuspensions,
    maxTotalSleep,
  );
}

/// [ResourceLimits]'s internal members (pass-3 G2): the package validates and
/// encodes limits, and upstream's `ResourceLimits` has neither. The public
/// libraries' `show` lists leave this extension out.
extension ResourceLimitsInternal on ResourceLimits {
  /// Throws [ArgumentError] for a negative limit, with upstream's message.
  void validate() {
    validateUnsigned(maxMemory, 'maxMemory');
    validateUnsigned(gcInterval, 'gcInterval');
    validateUnsigned(maxRecursionDepth, 'maxRecursionDepth');
    validateUnsigned(maxSuspensions, 'maxSuspensions');
    _duration(maxFeedDuration, 'maxFeedDuration');
    _duration(maxTurnDuration, 'maxTurnDuration');
    _duration(maxTotalSleep, 'maxTotalSleep');
  }

  /// The wire form: every set limit, and the two that cannot be off.
  pb.ResourceLimits toProto() => pb.ResourceLimits(
    maxMemoryBytes: _u64(maxMemory),
    gcInterval: _u64(gcInterval),
    maxRecursionDepth: Int64(maxRecursionDepth ?? defaultMaxRecursionDepth),
    maxSuspensions: Int64(maxSuspensions ?? defaultMaxSuspensions),
    maxFeedDurationMicros: _micros(maxFeedDuration),
    maxTurnDurationMicros: _micros(maxTurnDuration),
    maxTotalSleepMicros: _micros(maxTotalSleep),
  );
}

/// Upstream's `DEFAULT_MAX_RECURSION_DEPTH`.
const int defaultMaxRecursionDepth = 1000;

/// Upstream's `DEFAULT_MAX_SUSPENSIONS`.
const int defaultMaxSuspensions = 1000;

/// Upstream's text for a negative duration (Rust's `try_from_secs_f64`).
const String negativeDurationText =
    'cannot convert float seconds to Duration: value is negative';

/// Rust's `try_from_secs_f64` refusal of [d], or null when Rust has such a
/// `Duration`: not negative, and at most `u64::MAX` seconds, which only a
/// dart2js [Duration] can pass.
String? durationRefusal(Duration d) {
  if (d.isNegative) return negativeDurationText;
  if (d.inMicroseconds.toDouble() >= _twoTo64 * 1000000) {
    return 'cannot convert float seconds to Duration: value is either too '
        'big or NaN';
  }

  return null;
}

/// [d] in wire microseconds, saturating at `u64::MAX` as upstream's
/// `micros_field` does; past 2^63 (dart2js only) as the u64's bits.
Int64 durationMicros(Duration d) {
  final micros = d.inMicroseconds;
  final asDouble = micros.toDouble();
  if (asDouble >= _twoTo64) return Int64(-1);
  if (asDouble < _twoTo63) return Int64(micros);

  return Int64.parseInt('${BigInt.from(micros) - (BigInt.one << 64)}');
}

const double _twoTo63 = _twoTo64 / 2;

/// Throws [ArgumentError] when [value], the argument [name], is not an
/// unsigned 64-bit integer, with upstream's `OverflowError` text: negative,
/// or (only dart2js holds one) 2^64 or more. Null is accepted.
void validateUnsigned(int? value, String name) {
  if (value == null) return;
  if (value < 0) {
    throw ArgumentError.value(
      value,
      name,
      "can't convert negative int to unsigned",
    );
  }
  // Only dart2js holds an int this large; the wire's u64 cannot.
  if (value.toDouble() >= _twoTo64) {
    throw ArgumentError.value(value, name, 'int too big to convert');
  }
}

const double _twoTo64 = 18446744073709551616.0;

void _duration(Duration? value, String name) {
  final refusal = value == null ? null : durationRefusal(value);
  if (refusal != null) throw ArgumentError.value(value, name, refusal);
}

/// Rust's `Debug` for a `Duration`, which upstream's limit messages print:
/// the largest unit with a non-zero whole part (`s`, `ms`, `µs`, `ns`), and
/// the fraction with its trailing zeros dropped (`1.5s`, `150ms`).
String rustDuration(Duration d) => rustDurationNanos(nanosOf(d));

/// [rustDuration] for a duration of [nanos] nanoseconds, which a Dart
/// [Duration] cannot always hold (below a microsecond, or past 2^53
/// microseconds on dart2js).
String rustDurationNanos(BigInt nanos) {
  final seconds = nanos ~/ _nanosPerSecond;
  final rest = (nanos % _nanosPerSecond).toInt();
  if (seconds > BigInt.zero) {
    return _decimal('$seconds', rest, 100000000, 's');
  }
  if (rest >= 1000000) {
    return _decimal('${rest ~/ 1000000}', rest % 1000000, 100000, 'ms');
  }
  if (rest >= 1000) return _decimal('${rest ~/ 1000}', rest % 1000, 100, 'µs');

  return '${rest}ns';
}

String _decimal(String whole, int fraction, int divisor, String unit) {
  final digits = StringBuffer();
  var rest = fraction;
  var place = divisor;
  while (rest > 0 && place > 0) {
    digits.write(rest ~/ place);
    rest %= place;
    place ~/= 10;
  }

  return digits.isEmpty ? '$whole$unit' : '$whole.$digits$unit';
}

/// [d] in nanoseconds.
BigInt nanosOf(Duration d) => BigInt.from(d.inMicroseconds) * BigInt.from(1000);

final BigInt _nanosPerSecond = BigInt.from(1000000000);

/// Rust's `Duration::MAX` in nanoseconds: `u64::MAX` seconds and
/// 999999999 nanoseconds.
final BigInt durationMaxNanos =
    ((BigInt.one << 64) - BigInt.one) * _nanosPerSecond +
    BigInt.from(999999999);

/// Rust's `Duration::try_from_secs_f64` in nanoseconds: the exact value of
/// [seconds] rounded to the nearest nanosecond, ties to even; null where
/// Rust fails (negative, NaN, infinite, or past `u64::MAX` seconds).
///
/// Exact on every compiler: the double is taken apart into its integer
/// significand and binary exponent, and the arithmetic is on [BigInt]s.
BigInt? nanosFromSeconds(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) return null;
  final (significand, exponent) = _binaryParts(seconds);
  final scaled = significand * _nanosPerSecond;
  final nanos = exponent >= 0
      ? scaled << exponent
      : _divideToNearestEven(scaled, BigInt.one << -exponent);

  return nanos > durationMaxNanos ? null : nanos;
}

/// A finite, non-negative [value] as `significand * 2^exponent`, with an
/// integer significand: IEEE 754's fields, read through their bytes.
(BigInt, int) _binaryParts(double value) {
  final bits = ByteData(8)..setFloat64(0, value);
  final high = bits.getUint32(0);
  final biased = (high >> 20) & 0x7ff;
  final fraction =
      (BigInt.from(high & 0xfffff) << 32) | BigInt.from(bits.getUint32(4));
  // A normal double has an implicit leading bit; a subnormal (or zero) does
  // not, and has the smallest exponent.
  if (biased == 0) return (fraction, -1074);

  return (fraction | (BigInt.one << 52), biased - 1075);
}

/// [n] / [d] rounded to the nearest integer, ties to even.
BigInt _divideToNearestEven(BigInt n, BigInt d) {
  final q = n ~/ d;
  final twice = (n - q * d) * BigInt.two;
  final up = twice > d || (twice == d && q.isOdd);

  return up ? q + BigInt.one : q;
}

Int64? _u64(int? value) => value == null ? null : Int64(value);

Int64? _micros(Duration? value) => value == null ? null : durationMicros(value);
