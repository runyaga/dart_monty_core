/// Records lightweight worker metadata after a full integrity verification.
///
/// The fingerprint detects accidental corruption and ordinary edits because
/// size, modification time, and change time change on macOS and Linux. On
/// Windows, [FileStat.changed] is the file creation time, not the metadata
/// change time, so the fingerprint is size, mtime, and creation time. A
/// same-size Windows modification with the mtime restored is not detected
/// until the next full hash. The full SHA-256 runs at install and after a
/// mismatch.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

/// Metadata that identifies one verified worker file and manifest entry.
@immutable
final class WorkerFingerprint {
  /// Creates a worker fingerprint.
  const WorkerFingerprint({
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
    required this.entry,
  });

  /// Parses a strictly shaped fingerprint JSON value.
  factory WorkerFingerprint.fromJson(Object? value) {
    if (value is! Map || value.length != 4) {
      throw const FormatException(
        'worker fingerprint must be a four-field map',
      );
    }
    final fields = <String, Object?>{};
    for (final item in value.entries) {
      if (item.key is! String) {
        throw const FormatException('worker fingerprint keys must be strings');
      }
      fields[item.key as String] = item.value;
    }
    const names = {'size', 'modifiedMicros', 'changedMicros', 'entry'};
    if (!fields.keys.toSet().containsAll(names)) {
      throw const FormatException('worker fingerprint fields are invalid');
    }
    final size = fields['size'];
    final modifiedMicros = fields['modifiedMicros'];
    final changedMicros = fields['changedMicros'];
    final entry = fields['entry'];
    if (size is! int ||
        modifiedMicros is! int ||
        changedMicros is! int ||
        entry is! String) {
      throw const FormatException('worker fingerprint field types are invalid');
    }

    return WorkerFingerprint(
      size: size,
      modifiedMicros: modifiedMicros,
      changedMicros: changedMicros,
      entry: entry,
    );
  }

  /// Worker byte length.
  final int size;

  /// Worker modification time in microseconds since the Unix epoch.
  final int modifiedMicros;

  /// Worker change time in microseconds since the Unix epoch.
  ///
  /// On Windows, [FileStat.changed] is the file creation time rather than the
  /// metadata change time.
  final int changedMicros;

  /// Hash that identifies the manifest entry used for verification.
  final String entry;

  /// Converts this fingerprint into JSON-safe values.
  Map<String, Object> toJson() => {
    'size': size,
    'modifiedMicros': modifiedMicros,
    'changedMicros': changedMicros,
    'entry': entry,
  };

  @override
  bool operator ==(Object other) =>
      other is WorkerFingerprint &&
      size == other.size &&
      modifiedMicros == other.modifiedMicros &&
      changedMicros == other.changedMicros &&
      entry == other.entry;

  @override
  int get hashCode => Object.hash(size, modifiedMicros, changedMicros, entry);
}

/// Returns the fingerprint record path next to [workerFile].
String workerFingerprintPath(String workerFile) =>
    path.join(File(workerFile).parent.path, '.fingerprint');

/// Reads [workerFile]'s fingerprint record, or null when it is unusable.
WorkerFingerprint? readWorkerFingerprint(File workerFile) {
  try {
    final record = File(workerFingerprintPath(workerFile.path));

    return WorkerFingerprint.fromJson(jsonDecode(record.readAsStringSync()));
  } on Object {
    return null;
  }
}

/// Stats [workerFile] into a fingerprint for [entry], or returns null.
WorkerFingerprint? statWorkerFingerprint(File workerFile, String entry) {
  try {
    final stat = workerFile.statSync();
    if (stat.type != FileSystemEntityType.file) return null;

    return WorkerFingerprint(
      size: stat.size,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
      changedMicros: stat.changed.microsecondsSinceEpoch,
      entry: entry,
    );
  } on FileSystemException {
    return null;
  }
}

/// Writes an observed [fingerprint] record atomically next to [workerFile].
void writeWorkerFingerprint(File workerFile, WorkerFingerprint fingerprint) {
  final record = File(workerFingerprintPath(workerFile.path));
  final temporary = File(
    '${record.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    temporary
      ..writeAsStringSync(jsonEncode(fingerprint.toJson()), flush: true)
      ..renameSync(record.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

/// Returns the manifest-entry key used to bind a fingerprint to [artifact].
String workerEntryKey(WorkerArtifact artifact, {String? version}) {
  final entry =
      '${version ?? ''}|${artifact.file}|'
      '${artifact.bytes}|${artifact.sha256}';

  return sha256.convert(utf8.encode(entry)).toString();
}
