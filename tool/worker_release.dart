/// Packs and verifies the native worker files published with a release.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:path/path.dart' as path;

const _targets = {
  'linux-arm64': _TargetFiles('dart_monty_worker', 'libdart_monty_worker.so'),
  'linux-x64': _TargetFiles('dart_monty_worker', 'libdart_monty_worker.so'),
  'macos-arm64': _TargetFiles(
    'dart_monty_worker',
    'libdart_monty_worker.dylib',
  ),
  'windows-x64': _TargetFiles(
    'dart_monty_worker.exe',
    'dart_monty_worker.dll',
  ),
};

/// Runs the release-asset command specified by [arguments].
void runWorkerRelease(List<String> arguments) {
  switch (arguments) {
    case []:
      throw const WorkerRelease(_usage);
    case [final command, ...final options]:
      _runWorkerReleaseCommand(command, options);
  }
}

void _runWorkerReleaseCommand(String command, List<String> arguments) {
  final options = _Options.parse(arguments);
  switch (command) {
    case 'pack':
      packWorkerRelease(
        options.require('target'),
        Directory(options.require('bin-dir')),
        Directory(options.require('out')),
      );
    case 'manifest':
      writeWorkerReleaseManifest(
        options.require('tag'),
        Directory(options.require('fragments')),
        File(options.require('out')),
        allowPartial: options.has('allow-partial'),
      );
    case 'verify':
      verifyWorkerRelease(
        File(options.require('manifest')),
        Directory(options.require('assets')),
      );
    default:
      throw WorkerRelease('unknown command "$command".\n$_usage');
  }
}

/// Packs [target]'s worker and host library from [binDir] into [out].
void packWorkerRelease(
  String target,
  Directory binDir,
  Directory out,
) {
  final names = _targets[target];
  if (names == null) {
    throw WorkerRelease('unsupported target "$target".');
  }
  final worker = _readRequired(binDir, names.worker);
  final library = _readRequired(binDir, names.library);
  out.createSync(recursive: true);
  final entry = <String, Object?>{
    'worker': _packArtifact(target, names.worker, worker, out, false),
    'library': _packArtifact(target, names.library, library, out, true),
  };
  _writeJson(File(path.join(out.path, '$target.fragment.json')), entry);
}

/// Merges worker fragments from [fragments] into the manifest at [out].
void writeWorkerReleaseManifest(
  String tag,
  Directory fragments,
  File out, {
  required bool allowPartial,
}) {
  if (tag.isEmpty) throw const WorkerRelease('tag must not be empty.');
  final targets = _readFragments(fragments);
  final missing = _targets.keys.where((target) => !targets.containsKey(target));
  if (!allowPartial && missing.isNotEmpty) {
    throw WorkerRelease('missing fragments for: ${missing.join(', ')}.');
  }
  final manifest = <String, Object?>{
    'schema': 1,
    'version': tag,
    'targets': targets,
  };
  final source = const JsonEncoder.withIndent('  ').convert(manifest);
  WorkerManifest.fromJson(source);
  _writeText(out, '$source\n');
}

/// Verifies every archive described by [manifestFile] against [assets].
void verifyWorkerRelease(File manifestFile, Directory assets) {
  if (!manifestFile.existsSync()) {
    throw WorkerRelease('manifest is missing: ${manifestFile.path}.');
  }
  if (!assets.existsSync()) {
    throw WorkerRelease('assets directory is missing: ${assets.path}.');
  }
  final manifest = WorkerManifest.fromJson(manifestFile.readAsStringSync());
  final archives = _archivesFor(manifest);
  _verifyNoExtraArchives(assets, archives.keys);
  for (final name in archives.keys) {
    _verifyArchive(File(path.join(assets.path, name)), archives[name]!);
  }
}

/// A release-tool failure that names the invalid input or failed check.
final class WorkerRelease implements Exception {
  /// Creates an error with [message].
  const WorkerRelease(this.message);

  /// Explains the release-tool failure.
  final String message;

  @override
  String toString() => message;
}

List<int> _readRequired(Directory directory, String name) {
  final file = File(path.join(directory.path, name));
  if (!file.existsSync()) {
    throw WorkerRelease('required file is missing: ${file.path}.');
  }
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) {
    throw WorkerRelease('required file is empty: ${file.path}.');
  }

  return bytes;
}

Map<String, Object?> _packArtifact(
  String target,
  String file,
  List<int> contents,
  Directory out,
  bool library,
) {
  final prefix = library ? 'dart_monty_worker_library' : 'dart_monty_worker';
  final archiveName = '$prefix-$target.gz';
  final archive = GZipCodec().encode(contents);
  File(path.join(out.path, archiveName)).writeAsBytesSync(archive, flush: true);

  return {
    'file': file,
    'bytes': contents.length,
    'sha256': _digest(contents),
    'archive': <String, Object?>{
      'name': archiveName,
      'bytes': archive.length,
      'sha256': _digest(archive),
    },
  };
}

Map<String, Object?> _readFragments(Directory directory) {
  if (!directory.existsSync()) {
    throw WorkerRelease(
      'fragments directory is missing: ${directory.path}.',
    );
  }
  final entries = directory.listSync().whereType<File>();
  final fragments = entries.where(
    (entry) => entry.path.endsWith('.fragment.json'),
  );
  final targets = <String, Object?>{};
  for (final entry in fragments) {
    final target = path.basename(entry.path).replaceFirst('.fragment.json', '');
    if (!_targets.containsKey(target)) {
      throw WorkerRelease('fragment has unsupported target "$target".');
    }
    if (targets.containsKey(target)) {
      throw WorkerRelease('duplicate fragment for target "$target".');
    }
    targets[target] = _jsonMap(
      File(entry.path).readAsStringSync(),
      entry.path,
    );
  }

  return {
    for (final target in _targets.keys)
      if (targets.containsKey(target)) target: targets[target],
  };
}

Map<String, Object?> _jsonMap(String source, String file) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException();

    return {
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  } on FormatException {
    throw WorkerRelease('fragment is not a JSON object: $file.');
  }
}

Map<String, _ArchivedArtifact> _archivesFor(WorkerManifest manifest) {
  final found = <String, _ArchivedArtifact>{};
  for (final target in _targets.keys) {
    final entry = manifest.targets[target];
    if (entry == null) continue;
    _addArchive(found, entry.worker);
    final library = entry.library;
    if (library != null) _addArchive(found, library);
  }

  return found;
}

void _addArchive(
  Map<String, _ArchivedArtifact> found,
  WorkerArtifact artifact,
) {
  final archive = artifact.archive;
  if (archive == null) {
    throw WorkerRelease('${artifact.file}: archive is required.');
  }
  if (found.containsKey(archive.name)) {
    throw WorkerRelease(
      '${archive.name}: archive is listed more than once.',
    );
  }
  found[archive.name] = _ArchivedArtifact(artifact, archive);
}

void _verifyNoExtraArchives(Directory assets, Iterable<String> expected) {
  final known = expected.toSet();
  final entries = assets.listSync().whereType<File>();
  for (final entry in entries) {
    final name = path.basename(entry.path);
    if (name.endsWith('.gz') && !known.contains(name)) {
      throw WorkerRelease('$name: archive is not listed in the manifest.');
    }
  }
}

void _verifyArchive(File file, _ArchivedArtifact expected) {
  final name = expected.archive.name;
  if (!file.existsSync()) {
    throw WorkerRelease('$name: archive is missing.');
  }
  final archive = file.readAsBytesSync();
  _checkValue(name, 'archive bytes', archive.length, expected.archive.bytes);
  _checkValue(
    name,
    'archive sha256',
    _digest(archive),
    expected.archive.sha256,
  );
  final contents = _gunzip(name, archive);
  _checkValue(name, 'worker bytes', contents.length, expected.artifact.bytes);
  _checkValue(
    name,
    'worker sha256',
    _digest(contents),
    expected.artifact.sha256,
  );
  stdout.writeln('$name ${archive.length} ${_digest(archive)}');
}

List<int> _gunzip(String name, List<int> archive) {
  try {
    return GZipCodec().decode(archive);
  } on FormatException {
    throw WorkerRelease('$name: gzip decode failed.');
  }
}

void _checkValue(String name, String check, Object actual, Object expected) {
  if (actual != expected) {
    throw WorkerRelease('$name: $check mismatch.');
  }
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

void _writeJson(File file, Object value) =>
    _writeText(file, '${const JsonEncoder.withIndent('  ').convert(value)}\n');

void _writeText(File file, String contents) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents, flush: true);
}

final class _TargetFiles {
  const _TargetFiles(this.worker, this.library);

  final String worker;
  final String library;
}

final class _ArchivedArtifact {
  const _ArchivedArtifact(this.artifact, this.archive);

  final WorkerArtifact artifact;
  final WorkerArchive archive;
}

final class _Options {
  const _Options(this._values);

  factory _Options.parse(Iterable<String> arguments) {
    final values = <String, String?>{};
    final iterator = arguments.iterator;
    while (iterator.moveNext()) {
      final argument = iterator.current;
      if (!argument.startsWith('--')) {
        throw WorkerRelease('unexpected argument "$argument".\n$_usage');
      }
      final name = argument.substring(2);
      if (name == 'allow-partial') {
        values[name] = null;
      } else if (!iterator.moveNext()) {
        throw WorkerRelease('missing value for --$name.');
      } else {
        values[name] = iterator.current;
      }
    }

    return _Options(values);
  }

  final Map<String, String?> _values;

  bool has(String name) => _values.containsKey(name);

  String require(String name) {
    final value = _values[name];
    if (value == null || value.isEmpty) {
      throw WorkerRelease('missing required --$name.');
    }

    return value;
  }
}

const _usage =
    'usage:\n'
    '  dart run tool/worker_release.dart pack --target <key> --bin-dir <dir> --out <dir>\n'
    '  dart run tool/worker_release.dart manifest --tag <tag> --fragments <dir> --out <file> [--allow-partial]\n'
    '  dart run tool/worker_release.dart verify --manifest <file> --assets <dir>';

void main(List<String> arguments) {
  try {
    runWorkerRelease(arguments);
  } on WorkerRelease catch (error) {
    stderr.writeln('worker_release: $error');
    exitCode = 1;
  } on WorkerManifestError catch (error) {
    stderr.writeln('worker_release: $error');
    exitCode = 1;
  }
}
