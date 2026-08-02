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
const conformanceVfs = <String, String>{
  '/virtual/file.txt': 'hello from virtual fs',
  '/virtual/empty.txt': '',
  '/virtual/subdir/nested.txt': 'nested content',
  '/virtual/subdir/deep/file.txt': 'deep',
};

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
    vfs: Map.of(conformanceVfs),
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
        return const MontyDate(year: 2024, month: 1, day: 15);

      case 'datetime.now':
        final tz = args.isNotEmpty ? args.first : null;
        if (tz is MontyTimeZone) {
          return MontyDateTime(
            year: 2024,
            month: 1,
            day: 15,
            hour: 10,
            minute: 30,
            second: 0,
            offsetSeconds: tz.offsetSeconds,
            timezoneName: tz.name,
          );
        }

        return const MontyDateTime(
          year: 2024,
          month: 1,
          day: 15,
          hour: 10,
          minute: 30,
          second: 0,
        );

      default:
        return fs(operation, args, kwargs);
    }
  };
}
