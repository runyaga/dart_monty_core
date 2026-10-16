import 'dart:typed_data';
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
///
/// **Every entry is declared by `pathlib__os.py`, and the content is not
/// arbitrary.** That fixture asserts, among others:
///
///     Path('/virtual/file.txt').read_text() == 'hello world\n'
///     Path('/virtual/file.txt').stat().st_size == 12
///     Path('/virtual/data.bin').read_bytes() == b'\x00\x01\x02\x03'
///     len(list(Path('/virtual').iterdir())) == 5
///
/// `link.txt` exists to make that count five — it is otherwise unread, and
/// deleting it as dead weight would break the listing assertion.
List<AbstractFile> conformanceVfs() => [
  MemoryFile('/virtual/file.txt', 'hello world\n'),
  MemoryFile('/virtual/empty.txt', ''),
  MemoryFile('/virtual/data.bin', Uint8List.fromList([0, 1, 2, 3])),
  MemoryFile('/virtual/link.txt', 'link'),
  MemoryFile('/virtual/subdir/nested.txt', 'nested content'),
  MemoryFile('/virtual/subdir/deep/file.txt', 'deep'),
];

/// The filesystem the `# mount-fs` fixtures expect under `/mnt`.
///
/// A mirror of upstream's `create_mount_fs_tempdir`
/// (monty-datatest/src/main.rs:371-382), which is what those fixtures are
/// written against — `hello.txt` is 12 bytes, `readonly.txt` is 16, and
/// `mount_fs__ops.py` asserts both through `stat().st_size`.
///
/// **`data.bin` is BYTES, not a string.** Upstream writes it as
/// `b"\x00\x01\x02\x03"`, and the fixture asserts `read_bytes()`.
///
/// A function, not a constant, for the same reason as [conformanceVfs]: files
/// are mutable, so every handler needs its own set.
List<AbstractFile> conformanceMountFsVfs() => [
  MemoryFile('/mnt/hello.txt', 'hello world\n'),
  MemoryFile('/mnt/empty.txt', ''),
  MemoryFile('/mnt/data.bin', Uint8List.fromList([0, 1, 2, 3])),
  MemoryFile('/mnt/readonly.txt', 'readonly content'),
  MemoryFile('/mnt/subdir/nested.txt', 'nested content'),
  MemoryFile('/mnt/subdir/deep/file.txt', 'deep file'),
];

/// An [OsHandler] for the `# mount-fs` fixtures, serving
/// [conformanceMountFsVfs] under `/mnt` until F-2 supplies host mounts.
///
/// Filesystem only — those fixtures ask nothing of the clock or the
/// environment, and answering questions they do not pose would be inventing
/// contract. The non-filesystem ops live in [conformanceOsHandler].
OsHandler conformanceMountFsOsHandler() => OSAccess(
  files: conformanceMountFsVfs(),
).call;

/// The instant `datetime__core.py` is written against: 1700000000 UTC, i.e.
/// 2023-11-14 22:13:20 UTC. The virtual local zone is UTC+02:00, so a NAIVE
/// `datetime.now()` reads 2023-11-15 00:13:20 and `date.today()` is
/// 2023-11-15.
///
/// These are upstream's numbers, not ours (monty-datatest/src/main.rs): a
/// contract the fixture asserts.
const _fixtureEpochSeconds = 1700000000;

/// An [OsHandler] answering the OS calls the corpus makes.
///
/// **The clock is frozen on purpose.** `datetime__core.py` asserts an exact
/// date, so a real clock would make the fixture fail every day but one. A host
/// answering `datetime.now` is the sandbox's only source of time, which is the
/// property being demonstrated: the host decides what "now" means.
///
/// Filesystem calls fall through to [OSAccess] rather than being
/// reimplemented: the point is to exercise the SHIPPED handler, not a test
/// double. The handler is synchronous, so the filesystem handler's decline
/// ([OsCallNotHandledException]) still declines.
OsHandler conformanceOsHandler() {
  final fs = OSAccess(
    files: conformanceVfs(),
  );

  return (name, args, kwargs) {
    switch (name) {
      case 'os.getenv':
        final key = (args.first as MontyString).value;
        final value = conformanceEnv[key];
        if (value != null) return MontyString(value);

        return args.length > 1 ? args[1] : const MontyNone();

      case 'os.environ':
        return MontyDict([
          for (final e in conformanceEnv.entries)
            (MontyString(e.key), MontyString(e.value)),
        ]);

      case 'date.today':
        return const MontyDate(year: 2023, month: 11, day: 15);

      case 'datetime.now':
        final tz = args.isNotEmpty ? args.first : null;
        if (tz is MontyTimeZone) {
          // Aware: the fixture timestamp in the requested zone.
          final local = DateTime.fromMillisecondsSinceEpoch(
            (_fixtureEpochSeconds + tz.offsetSeconds) * 1000,
            isUtc: true,
          );

          return MontyDateTime(
            year: local.year,
            month: local.month,
            day: local.day,
            hour: local.hour,
            minute: local.minute,
            second: local.second,
            offsetSeconds: tz.offsetSeconds,
            timezoneName: tz.name,
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
        return fs(name, args, kwargs);
    }
  };
}
