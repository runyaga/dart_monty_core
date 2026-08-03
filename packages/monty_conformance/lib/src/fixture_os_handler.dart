import 'package:dart_monty_core/dart_monty_core.dart';

/// The environment `# call-external` fixtures expect `os.getenv` / `os.environ`
/// to report.
///
/// Values are upstream's, not ours — `os__environ.py` asserts them by name, so
/// this is a contract.
const conformanceEnv = <String, String>{
  'VIRTUAL_HOME': '/virtual/home',
  'VIRTUAL_USER': 'testuser',
  'VIRTUAL_EMPTY': '',
};

/// The filesystem the non-`# mount-fs` path fixtures expect under `/virtual`.
///
/// A function, not a constant: files are mutable, so every handler must get
/// its own set or a write in one fixture would be visible to the next.
List<VfsFile> conformanceVfs() => [
  MontyMemoryFile('/virtual/file.txt', 'hello from virtual fs'),
  MontyMemoryFile('/virtual/empty.txt', ''),
  MontyMemoryFile('/virtual/subdir/nested.txt', 'nested content'),
  MontyMemoryFile('/virtual/subdir/deep/file.txt', 'deep'),
];

/// The instant `datetime__core.py` is written against: 1700000000 UTC, i.e.
/// 2023-11-14 22:13:20 UTC. The virtual local zone is UTC+02:00, so a NAIVE
/// `datetime.now()` reads 2023-11-15 00:13:20 and `date.today()` is
/// 2023-11-15.
///
/// These are upstream's numbers, not ours (monty-datatest/src/main.rs:937-942
/// and :1233-1272). The handler previously invented 2024-01-15 10:30, which
/// was plausible and wrong, and it was the only reason the fixture failed —
/// the values are a contract the fixture asserts, discoverable from upstream's
/// runner rather than something to guess.
const _fixtureEpochSeconds = 1700000000;

/// An [OsCallHandler] answering the OS calls the corpus makes.
///
/// **The clock is frozen on purpose.** `datetime__core.py` asserts an exact
/// date, so a real clock would make the fixture fail every day but one. A host
/// answering `datetime.now` is the sandbox's only source of time, which is the
/// property being demonstrated: the host decides what "now" means.
///
/// Filesystem calls fall through to [memoryMountedOsHandler] rather than being
/// reimplemented — the point of running these in the demo is to exercise the
/// SHIPPED handler, not a test double.
OsCallHandler conformanceOsHandler() {
  final fs = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/virtual')],
    files: conformanceVfs(),
  );

  return (operation, args, kwargs) async {
    switch (operation) {
      case 'os.getenv':
        final key = args.first! as String;
        if (conformanceEnv.containsKey(key)) return conformanceEnv[key];

        return args.length > 1 ? args[1] : null;

      case 'os.environ':
        return Map<String, String>.of(conformanceEnv);

      case 'date.today':
        return const MontyDate(year: 2023, month: 11, day: 15);

      case 'datetime.now':
        // An OsCallHandler receives `dartValue`s, so a timezone argument
        // arrives as its MAP form — `{__type: timezone, offset_seconds: 0,
        // name: null}` — never as a MontyTimeZone. This branch used to test
        // `is MontyTimeZone` and was therefore dead: every aware
        // `datetime.now(tz)` silently got the NAIVE datetime back, so
        // `now_utc.tzinfo` was None and datetime__core.py:17 failed on
        // `assert now_utc.tzinfo is datetime.timezone.utc`.
        final tz = args.isNotEmpty ? args.first : null;
        if (tz is Map && tz['__type'] == 'timezone') {
          final offsetSeconds = (tz['offset_seconds'] as num?)?.toInt() ?? 0;
          // Aware: convert the fixture timestamp into the requested zone.
          final local = DateTime.fromMillisecondsSinceEpoch(
            (_fixtureEpochSeconds + offsetSeconds) * 1000,
            isUtc: true,
          );

          return MontyDateTime(
            year: local.year,
            month: local.month,
            day: local.day,
            hour: local.hour,
            minute: local.minute,
            second: local.second,
            offsetSeconds: offsetSeconds,
            timezoneName: tz['name'] as String?,
          );
        }

        // Naive: the fixture timestamp read in the virtual local zone,
        // 1700000000 + 7200 = 2023-11-15 00:13:20.
        return const MontyDateTime(
          year: 2023,
          month: 11,
          day: 15,
          hour: 0,
          minute: 13,
          second: 20,
        );

      default:
        return fs(operation, args, kwargs);
    }
  };
}
