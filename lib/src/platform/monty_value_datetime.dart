part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// DateTime types
// ---------------------------------------------------------------------------

/// Represents a Python `datetime.date` value.
@immutable
final class MontyDate extends MontyValue {
  /// Creates a [MontyDate] with the given [year], [month], and [day].
  const MontyDate({required this.year, required this.month, required this.day});

  factory MontyDate._fromMap(Map<String, dynamic> map) => MontyDate(
    year: (map['year'] as num).toInt(),
    month: (map['month'] as num).toInt(),
    day: (map['day'] as num).toInt(),
  );

  /// The year component.
  final int year;

  /// The month component (1-12).
  final int month;

  /// The day component (1-31).
  final int day;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'date',
    'year': year,
    'month': month,
    'day': day,
  };

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

  factory MontyDateTime._fromMap(Map<String, dynamic> map) => MontyDateTime(
    year: (map['year'] as num).toInt(),
    month: (map['month'] as num).toInt(),
    day: (map['day'] as num).toInt(),
    hour: (map['hour'] as num).toInt(),
    minute: (map['minute'] as num).toInt(),
    second: (map['second'] as num).toInt(),
    microsecond: (map['microsecond'] as num?)?.toInt() ?? 0,
    offsetSeconds: (map['offset_seconds'] as num?)?.toInt(),
    timezoneName: map['timezone_name'] as String?,
  );

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

  @override
  Map<String, Object?> toJson() => {
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

  @override
  DateTime get dartValue => DateTime(
    year,
    month,
    day,
    hour,
    minute,
    second,
    0,
    microsecond,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyDateTime && _fieldsEqual(other));

  bool _fieldsEqual(MontyDateTime o) =>
      o.year == year &&
      o.month == month &&
      o.day == day &&
      o.hour == hour &&
      o.minute == minute &&
      o.second == second &&
      o.microsecond == microsecond &&
      o.offsetSeconds == offsetSeconds &&
      o.timezoneName == timezoneName;

  @override
  int get hashCode => Object.hash(
    year,
    month,
    day,
    hour,
    minute,
    second,
    microsecond,
    offsetSeconds,
    timezoneName,
  );

  @override
  String toString() =>
      'MontyDateTime($year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}T'
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')})';
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

  factory MontyTimeDelta._fromMap(Map<String, dynamic> map) => MontyTimeDelta(
    days: (map['days'] as num).toInt(),
    seconds: (map['seconds'] as num).toInt(),
    microseconds: (map['microseconds'] as num?)?.toInt() ?? 0,
  );

  /// The number of days.
  final int days;

  /// The number of seconds (0-86399).
  final int seconds;

  /// The number of microseconds (0-999999).
  final int microseconds;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'timedelta',
    'days': days,
    'seconds': seconds,
    'microseconds': microseconds,
  };

  @override
  Duration get dartValue => Duration(
    days: days,
    seconds: seconds,
    microseconds: microseconds,
  );

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
}

/// Represents a Python `datetime.timezone` value.
@immutable
final class MontyTimeZone extends MontyValue {
  /// Creates a [MontyTimeZone] with the given [offsetSeconds] and [name].
  const MontyTimeZone({required this.offsetSeconds, this.name});

  factory MontyTimeZone._fromMap(Map<String, dynamic> map) => MontyTimeZone(
    offsetSeconds: (map['offset_seconds'] as num).toInt(),
    name: map['name'] as String?,
  );

  /// The UTC offset in seconds.
  final int offsetSeconds;

  /// The timezone name, or `null` if unnamed.
  final String? name;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'timezone',
    'offset_seconds': offsetSeconds,
    'name': name,
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeZone &&
          other.offsetSeconds == offsetSeconds &&
          other.name == name);

  @override
  int get hashCode => Object.hash(offsetSeconds, name);

  @override
  String toString() => 'MontyTimeZone(offset=$offsetSeconds, name=$name)';
}

/// Python's `datetime.time`.
///
/// ADDED 2026-09-14 after an encoder/decoder alignment audit. The Rust encoder
/// has emitted `{"__type": "time", ...}` all along (native/src/convert.rs:174)
/// and Dart had NO factory for it, so `datetime.time(12, 0)` crossing the
/// boundary threw `FormatException: unknown __type "time"`. Same class of
/// defect as the `class_instance` gap, found the same way: by enumerating what
/// the encoder can emit rather than trusting the decoder's list.
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

  factory MontyTime._fromMap(Map<String, dynamic> map) => MontyTime(
    hour: (map['hour'] as num?)?.toInt() ?? 0,
    minute: (map['minute'] as num?)?.toInt() ?? 0,
    second: (map['second'] as num?)?.toInt() ?? 0,
    microsecond: (map['microsecond'] as num?)?.toInt() ?? 0,
    offsetSeconds: (map['offset_seconds'] as num?)?.toInt(),
    timezoneName: map['timezone_name'] as String?,
    fold: (map['fold'] as num?)?.toInt() ?? 0,
  );

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

  @override
  Map<String, Object?> toJson() => {
    '__type': 'time',
    'hour': hour,
    'minute': minute,
    'second': second,
    'microsecond': microsecond,
    'offset_seconds': offsetSeconds,
    'timezone_name': timezoneName,
    'fold': fold,
  };

  /// Dart has no time-of-day type in `dart:core`, so this represents itself
  /// rather than lying about being a [DateTime] on an arbitrary date.
  @override
  Object? get dartValue => this;

  @override
  String toString() =>
      'MontyTime($hour:$minute:$second.$microsecond'
      '${offsetSeconds == null ? '' : ' offset=$offsetSeconds'})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTime &&
          other.hour == hour &&
          other.minute == minute &&
          other.second == second &&
          other.microsecond == microsecond &&
          other.offsetSeconds == offsetSeconds &&
          other.timezoneName == timezoneName &&
          other.fold == fold);

  @override
  int get hashCode => Object.hash(
    hour,
    minute,
    second,
    microsecond,
    offsetSeconds,
    timezoneName,
    fold,
  );
}
