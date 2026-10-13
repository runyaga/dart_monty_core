/// Upstream's `ResourceLimits`, its validation and its `Configure`
/// encoding, and the Rust `Duration` format its limit messages use.
///
/// Upstream's is a TypedDict (`pydantic_monty/__init__.py`); here it is a
/// small immutable class whose durations are [Duration]s. A value upstream's
/// argument parsing refuses is an [ArgumentError] with upstream's message,
/// raised by [ResourceLimits.validate] at checkout.
///
/// Internal until the cutover exports it; nothing here is exported.
library;

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:meta/meta.dart';

/// Upstream's `ResourceLimits`: the limits one session runs under.
///
/// A null limit is off, except [maxRecursionDepth] and [maxSuspensions],
/// which cannot be turned off: null keeps upstream's default of 1000.
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

  /// Throws [ArgumentError] for a negative limit, with upstream's message.
  void validate() {
    _unsigned(maxMemory, 'maxMemory');
    _unsigned(gcInterval, 'gcInterval');
    _unsigned(maxRecursionDepth, 'maxRecursionDepth');
    _unsigned(maxSuspensions, 'maxSuspensions');
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
    maxFeedDurationMicros: _u64(maxFeedDuration?.inMicroseconds),
    maxTurnDurationMicros: _u64(maxTurnDuration?.inMicroseconds),
    maxTotalSleepMicros: _u64(maxTotalSleep?.inMicroseconds),
  );
}

/// Upstream's `DEFAULT_MAX_RECURSION_DEPTH`.
const int defaultMaxRecursionDepth = 1000;

/// Upstream's `DEFAULT_MAX_SUSPENSIONS`.
const int defaultMaxSuspensions = 1000;

/// Upstream's text for a negative duration (Rust's `try_from_secs_f64`).
const String negativeDurationText =
    'cannot convert float seconds to Duration: value is negative';

void _unsigned(int? value, String name) {
  if (value != null && value < 0) {
    throw ArgumentError.value(
      value,
      name,
      "can't convert negative int to unsigned",
    );
  }
}

void _duration(Duration? value, String name) {
  if (value != null && value.isNegative) {
    throw ArgumentError.value(value, name, negativeDurationText);
  }
}

/// Rust's `Debug` for a `Duration`, which upstream's limit messages print:
/// the largest unit with a non-zero whole part (`s`, `ms`, `µs`, `ns`), and
/// the fraction with its trailing zeros dropped (`1.5s`, `150ms`).
String rustDuration(Duration d) {
  final micros = d.inMicroseconds;
  const perSecond = Duration.microsecondsPerSecond;
  final seconds = micros ~/ perSecond;
  final nanos = (micros % perSecond) * 1000;
  if (seconds > 0) return _decimal(seconds, nanos, 100000000, 's');
  if (nanos >= 1000000) {
    return _decimal(nanos ~/ 1000000, nanos % 1000000, 100000, 'ms');
  }
  if (nanos >= 1000) return _decimal(nanos ~/ 1000, nanos % 1000, 100, 'µs');

  return '${nanos}ns';
}

String _decimal(int whole, int fraction, int divisor, String unit) {
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

Int64? _u64(int? value) => value == null ? null : Int64(value);
