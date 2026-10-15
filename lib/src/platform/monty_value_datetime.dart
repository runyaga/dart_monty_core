part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// DateTime types
// ---------------------------------------------------------------------------

/// Represents a Python `datetime.date` value.
@immutable
final class MontyDate extends MontyValue {
  /// Creates a [MontyDate] with the given [year], [month], and [day].
  const MontyDate({required this.year, required this.month, required this.day});

  /// The year component.
  final int year;

  /// The month component (1-12).
  final int month;

  /// The day component (1-31).
  final int day;

  @override
  int get _graphKind => _kFixed;

  @override
  DateTime get dartValue => DateTime(year, month, day);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDate &&
          other.year == year &&
          other.month == month &&
          other.day == day);

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      'MontyDate($year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')})';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'date',
    'year': year,
    'month': month,
    'day': day,
  };
}

/// Represents a Python `datetime.datetime` value.
@immutable
final class MontyDateTime extends MontyValue {
  /// Creates a [MontyDateTime] with the given components.
  const MontyDateTime({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.microsecond = 0,
    this.offsetSeconds,
    this.timezoneName,
  });

  /// The year component.
  final int year;

  /// The month component (1-12).
  final int month;

  /// The day component (1-31).
  final int day;

  /// The hour component (0-23).
  final int hour;

  /// The minute component (0-59).
  final int minute;

  /// The second component (0-59).
  final int second;

  /// The microsecond component (0-999999).
  final int microsecond;

  /// The UTC offset in seconds, or `null` for naive datetimes.
  final int? offsetSeconds;

  /// The timezone name, or `null` for naive datetimes.
  final String? timezoneName;

  /// An aware datetime as a UTC [DateTime] at its instant; a naive one as a
  /// local [DateTime] from its fields. A [DateTime] has no zone name, so
  /// [timezoneName] stays on this value only.
  @override
  DateTime get dartValue => switch (offsetSeconds) {
    final offset? => DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second - offset,
      0,
      microsecond,
    ),
    null => DateTime(year, month, day, hour, minute, second, 0, microsecond),
  };

  /// As Python's: two aware datetimes are equal at the same instant,
  /// whatever their offsets and zone names; two naive ones when their fields
  /// are; a naive one never equals an aware one.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDateTime &&
          (offsetSeconds == null) == (other.offsetSeconds == null) &&
          (offsetSeconds == null
              ? _naiveEquals(other)
              : _instantSeconds == other._instantSeconds &&
                    microsecond == other.microsecond));

  bool _naiveEquals(MontyDateTime o) =>
      o.year == year &&
      o.month == month &&
      o.day == day &&
      o.hour == hour &&
      o.minute == minute &&
      o.second == second &&
      o.microsecond == microsecond;

  /// The whole seconds from 1970-01-01T00:00Z to an aware datetime's
  /// instant; exact on every compiler (under 2^53 for any Python date).
  int get _instantSeconds =>
      _daysFromCivil(year, month, day) * 86400 +
      hour * 3600 +
      minute * 60 +
      second -
      (offsetSeconds ?? 0);

  /// The hash of what [==] compares: the instant, or the naive fields.
  @override
  int get hashCode => offsetSeconds == null
      ? Object.hash(year, month, day, hour, minute, second, microsecond)
      : Object.hash(_instantSeconds, microsecond);

  @override
  String toString() =>
      'MontyDateTime($year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}T'
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')})';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'datetime',
    'year': year,
    'month': month,
    'day': day,
    'hour': hour,
    'minute': minute,
    'second': second,
    'microsecond': microsecond,
    'offset_seconds': offsetSeconds,
    'timezone_name': timezoneName,
  };
}

/// Represents a Python `datetime.timedelta` value.
@immutable
final class MontyTimeDelta extends MontyValue {
  /// Creates a [MontyTimeDelta] with the given components.
  const MontyTimeDelta({
    required this.days,
    required this.seconds,
    this.microseconds = 0,
  });

  /// The number of days.
  final int days;

  /// The number of seconds (0-86399).
  final int seconds;

  /// The number of microseconds (0-999999).
  final int microseconds;

  @override
  int get _graphKind => _kFixed;

  /// The [Duration] of exactly this timedelta.
  ///
  /// Throws [StateError] when a [Duration] cannot hold it exactly on this
  /// platform (beyond 2^63 microseconds, or 2^53 on dart2js), rather than
  /// truncating; the value itself stays usable.
  @override
  Duration get dartValue {
    final total =
        (BigInt.from(days) * BigInt.from(86400) + BigInt.from(seconds)) *
            BigInt.from(1000000) +
        BigInt.from(microseconds);
    if (!total.isValidInt || total.bitLength > _durationBits) {
      throw StateError(
        'timedelta(days=$days, seconds=$seconds, microseconds=$microseconds) '
        'is $total microseconds, which a Duration cannot hold exactly here',
      );
    }

    return Duration(microseconds: total.toInt());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeDelta &&
          other.days == days &&
          other.seconds == seconds &&
          other.microseconds == microseconds);

  @override
  int get hashCode => Object.hash(days, seconds, microseconds);

  @override
  String toString() => 'MontyTimeDelta(days=$days, seconds=$seconds)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'timedelta',
    'days': days,
    'seconds': seconds,
    'microseconds': microseconds,
  };
}

/// Represents a Python `datetime.timezone` value.
@immutable
final class MontyTimeZone extends MontyValue {
  /// Creates a [MontyTimeZone] with the given [offsetSeconds] and [name].
  const MontyTimeZone({required this.offsetSeconds, this.name});

  /// The UTC offset in seconds.
  final int offsetSeconds;

  /// The timezone name, or `null` if unnamed.
  final String? name;

  @override
  Map<String, Object?> get dartValue => _toJson();

  /// As Python's `timezone.__eq__`: by offset; the name is not compared.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeZone && other.offsetSeconds == offsetSeconds);

  @override
  int get hashCode => offsetSeconds.hashCode;

  @override
  String toString() => 'MontyTimeZone(offset=$offsetSeconds, name=$name)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'timezone',
    'offset_seconds': offsetSeconds,
    'name': name,
  };
}

/// Python's `datetime.time`.
///
/// Carries the same fields as the Rust arm, including the tz-aware ones — a
/// `time` can hold a UTC offset and a fold flag exactly as a `datetime` can.
@immutable
final class MontyTime extends MontyValue {
  /// Creates a [MontyTime].
  const MontyTime({
    required this.hour,
    required this.minute,
    required this.second,
    required this.microsecond,
    this.offsetSeconds,
    this.timezoneName,
    this.fold = 0,
  });

  /// Hour, 0-23.
  final int hour;

  /// Minute, 0-59.
  final int minute;

  /// Second, 0-59.
  final int second;

  /// Microsecond, 0-999999.
  final int microsecond;

  /// UTC offset in seconds, or null for a naive time.
  final int? offsetSeconds;

  /// The tzinfo name, if the time carries one.
  final String? timezoneName;

  /// Python's `fold`, disambiguating a repeated wall-clock time.
  final int fold;

  /// Dart has no time-of-day type in `dart:core`, so this represents itself
  /// rather than lying about being a [DateTime] on an arbitrary date.
  @override
  Object? get dartValue => this;

  @override
  String toString() =>
      'MontyTime($hour:$minute:$second.$microsecond'
      '${offsetSeconds == null ? '' : ' offset=$offsetSeconds'})';

  /// As Python's `time.__eq__`: two naive times by their fields; two aware
  /// ones by the minutes after subtracting each offset (floored to whole
  /// minutes, as Python does), not wrapped at midnight, then seconds and
  /// microseconds; a naive time never equals an aware one. [fold] and
  /// [timezoneName] are not compared.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTime &&
          (offsetSeconds == null) == (other.offsetSeconds == null) &&
          other._minutes == _minutes &&
          other.second == second &&
          other.microsecond == microsecond);

  /// The minutes of the day [==] compares: less the offset when aware.
  int get _minutes => hour * 60 + minute - ((offsetSeconds ?? 0) / 60).floor();

  /// The hash of what [==] compares.
  @override
  int get hashCode =>
      Object.hash(offsetSeconds == null, _minutes, second, microsecond);

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'time',
    'hour': hour,
    'minute': minute,
    'second': second,
    'microsecond': microsecond,
    'offset_seconds': offsetSeconds,
    'timezone_name': timezoneName,
    'fold': fold,
  };
}

/// The days from 1970-01-01 to the proleptic Gregorian date [y]-[m]-[d]
/// (Howard Hinnant's `days_from_civil`), exact for any Python date.
int _daysFromCivil(int y, int m, int d) {
  final yy = m <= 2 ? y - 1 : y;
  final era = (yy >= 0 ? yy : yy - 399) ~/ 400;
  final yoe = yy - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;

  return era * 146097 + doe - 719468;
}

/// The widest microsecond count a [Duration] holds exactly: 63 bits, or 53
/// on dart2js, where an `int` is a double.
const int _durationBits = identical(1, 1.0) ? 53 : 63;
