part of 'os_access.dart';

final class _OsAccessDefaults {
  _OsAccessDefaults(this.maxUrandomBytes, this.maxSleep) {
    if (maxUrandomBytes < 0) {
      throw ArgumentError('max_urandom_bytes must be non-negative');
    }
    if (maxSleep?.isNegative ?? false) {
      throw ArgumentError('max_sleep must be non-negative');
    }
  }
  final int maxUrandomBytes;
  final Duration? maxSleep;
  FutureOr<MontyValue> call(String name, List<MontyValue> args) =>
      switch (name) {
        'date.today' => _today(),
        'datetime.now' => _now(args.firstOrNull),
        'time.time' => MontyFloat(
          DateTime.now().microsecondsSinceEpoch / 1000000,
        ),
        'os.urandom' => _random(args.firstOrNull),
        'time.sleep' ||
        'asyncio.sleep' ||
        'system.sleep' ||
        'system.async_sleep' => _sleep(args.firstOrNull),
        _ => throw const OsCallNotHandledException(),
      };
  MontyBytes _random(MontyValue? arg) {
    if (arg is! MontyInt) {
      throw const ExternalException('TypeError', 'size must be an integer');
    }
    final size = arg.value;
    if (size > maxUrandomBytes) {
      throw ExternalException(
        'MemoryError',
        'os.urandom() size exceeds max_urandom_bytes ($maxUrandomBytes)',
      );
    }
    if (size < 0) {
      throw const ExternalException(
        'ValueError',
        'negative argument not allowed',
      );
    }
    final random = Random.secure();

    return MontyBytes(
      Uint8List.fromList(List.generate(size, (_) => random.nextInt(256))),
    );
  }

  Future<MontyValue> _sleep(MontyValue? arg) async {
    final seconds = switch (arg) {
      MontyInt(:final value) => value.toDouble(),
      MontyFloat(:final value) => value,
      _ => throw const ExternalException('TypeError', 'sleep expects a number'),
    };
    final cap = maxSleep;
    final capped = cap == null
        ? seconds
        : min(seconds, cap.inMicroseconds / 1000000);
    if (capped.isNaN) {
      throw const ExternalException(
        'ValueError',
        'Invalid value NaN (not a number)',
      );
    }
    if (capped < 0) {
      throw const ExternalException(
        'ValueError',
        'sleep length must be non-negative',
      );
    }
    if (!capped.isFinite) {
      throw const ExternalException(
        'OverflowError',
        'timestamp out of range for platform time_t',
      );
    }
    await Future<void>.delayed(
      Duration(microseconds: (capped * 1000000).round()),
    );

    return const MontyNone();
  }
}

MontyDate _today() {
  final now = DateTime.now();

  return MontyDate(year: now.year, month: now.month, day: now.day);
}

MontyDateTime _now(MontyValue? zone) {
  final tz = zone is MontyTimeZone ? zone : null;
  final now = tz == null
      ? DateTime.now()
      : DateTime.now().toUtc().add(Duration(seconds: tz.offsetSeconds));

  return MontyDateTime(
    year: now.year,
    month: now.month,
    day: now.day,
    hour: now.hour,
    minute: now.minute,
    second: now.second,
    microsecond: now.millisecond * 1000 + now.microsecond,
    offsetSeconds: tz?.offsetSeconds,
    timezoneName: tz?.name,
  );
}
