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
/// top-level `posix` and `right` directories), and a file that starts with
/// `TZif`. Null when the host has no zoneinfo directory.
bool? hostZoneKnown(String name) => zoneKnownIn(_zones, name);

/// Whether [zones] (from [zoneFilesUnder]) resolve [name]; null for none.
@visibleForTesting
bool? zoneKnownIn(Map<String, String>? zones, String name) {
  if (zones == null) return null;
  final path = zones[name.toLowerCase()];
  if (path == null) return false;
  try {
    final file = File(path).openSync();
    try {
      return String.fromCharCodes(file.readSync(4)) == 'TZif';
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return false;
  }
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
