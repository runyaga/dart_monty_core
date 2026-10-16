import 'package:dart_monty_core/src/platform/monty_value.dart';

/// Builders for the named stat tuple accepted by the worker.
abstract final class StatResult {
  StatResult._();

  /// A regular file, preserving full mode bits and using epoch seconds.
  static MontyNamedTuple fileStat(
    int size, [
    int mode = 0x1A4,
    double? mtime,
  ]) => _stat(mode < 0x200 ? mode | 0x8000 : mode, 1, size, mtime);

  /// A directory with two links and a conventional 4096-byte size.
  static MontyNamedTuple dirStat([int mode = 0x1ED, double? mtime]) =>
      _stat(mode < 0x200 ? mode | 0x4000 : mode, 2, 4096, mtime);
}

MontyNamedTuple _stat(int mode, int links, int size, double? mtime) {
  final time = MontyFloat(
    mtime ?? DateTime.now().microsecondsSinceEpoch / 1000000,
  );
  return MontyNamedTuple(
    typeName: 'StatResult',
    fieldNames: const [
      'st_mode',
      'st_ino',
      'st_dev',
      'st_nlink',
      'st_uid',
      'st_gid',
      'st_size',
      'st_atime',
      'st_mtime',
      'st_ctime',
    ],
    values: [
      MontyInt(mode),
      const MontyInt(0),
      const MontyInt(0),
      MontyInt(links),
      const MontyInt(0),
      const MontyInt(0),
      MontyInt(size),
      time,
      time,
      time,
    ],
  );
}
