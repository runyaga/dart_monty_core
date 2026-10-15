/// The zoneinfo directory jiff (the worker's tz library) opens on a native
/// host: `TZDIR`, else the first of its default directories that holds any
/// zone (jiff 0.2 `tz/db/zoneinfo/enabled.rs`, `Database::from_env`).
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:io';

import 'package:meta/meta.dart';

/// Whether the host's zoneinfo directory resolves [name] as jiff does:
/// matched ignoring ASCII case against the files under it (not in its
/// top-level `posix` and `right` directories), and a file whose TZif
/// structure is whole. Null when the host has no zoneinfo directory.
bool? hostZoneKnown(String name) => zoneKnownIn(_zones, name);

/// Whether [zones] (from [zoneFilesUnder]) resolve [name]; null for none.
@visibleForTesting
bool? zoneKnownIn(Map<String, String>? zones, String name) {
  if (zones == null) return null;
  final path = zones[name.toLowerCase()];
  if (path == null) return false;
  try {
    return isWholeTzif(File(path).readAsBytesSync());
  } on FileSystemException {
    return false;
  }
}

/// Whether [data] is TZif (RFC 8536) whose header counts fit the file: the
/// version 1 block, and for version 2 and later the second block and a
/// footer between newlines. A truncated or mislabelled file is refused, as
/// jiff's parse refuses it; the transitions themselves are not checked.
@visibleForTesting
bool isWholeTzif(List<int> data) {
  final v1 = _blockEnd(data, 0, 4);
  if (v1 == null) return false;
  if (data[4] == 0) return true;
  final v2 = _blockEnd(data, v1, 8);
  if (v2 == null || v2 >= data.length || data[v2] != 0x0A) return false;

  return data.indexOf(0x0A, v2 + 1) > v2;
}

/// The end of the TZif block whose header starts at [start], with times of
/// [timeSize] bytes; null when the header or its data does not fit.
int? _blockEnd(List<int> data, int start, int timeSize) {
  const headerLength = 44;
  if (data.length < start + headerLength) return null;
  if (String.fromCharCodes(data, start, start + 4) != 'TZif') return null;
  int count(int i) {
    final at = start + 20 + i * 4;

    return (data[at] << 24) |
        (data[at + 1] << 16) |
        (data[at + 2] << 8) |
        data[at + 3];
  }

  final [isUt, isStd, leap, times, types, chars] = [
    for (var i = 0; i < 6; i++) count(i),
  ];
  if (types == 0 || chars == 0) return null;
  final end =
      start +
      headerLength +
      times * (timeSize + 1) +
      types * 6 +
      chars +
      leap * (timeSize + 4) +
      isStd +
      isUt;

  return end <= data.length ? end : null;
}

/// jiff's default directories, after `TZDIR`.
const List<String> _defaultDirectories = [
  '/usr/share/zoneinfo',
  '/usr/share/lib/zoneinfo',
  '/etc/zoneinfo',
];

/// The host's zones, lower-cased name to path, read once.
final Map<String, String>? _zones = _open();

Map<String, String>? _open() {
  final tzdir = Platform.environment['TZDIR'];
  for (final dir in [?tzdir, ..._defaultDirectories]) {
    final zones = zoneFilesUnder(dir);
    if (zones.isNotEmpty) return zones;
  }

  return null;
}

/// Every file under [root], by its name relative to [root] in lower case,
/// as jiff's walk lists them: links count as files, and the top-level
/// `posix` and `right` directories are skipped.
@visibleForTesting
Map<String, String> zoneFilesUnder(String root) {
  final zones = <String, String>{};
  final base = Directory(root);
  if (!base.existsSync()) return zones;
  final prefix = '${base.path}/';
  try {
    for (final entry in base.listSync(recursive: true, followLinks: false)) {
      if (entry is Directory) continue;
      final relative = entry.path
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      if (relative.startsWith('posix/') || relative.startsWith('right/')) {
        continue;
      }
      zones[relative.toLowerCase()] = entry.path;
    }
  } on FileSystemException {
    return zones;
  }

  return zones;
}
