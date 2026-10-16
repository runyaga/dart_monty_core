import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:dart_monty_core/src/mount/abstract_file.dart';
import 'package:dart_monty_core/src/mount/file_content.dart';
import 'package:dart_monty_core/src/mount/memory_file.dart';
import 'package:dart_monty_core/src/mount/stat_result.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:dart_monty_core/src/worker/python_rules.dart';

part 'os_access_tree.dart';
part 'os_access_files.dart';
part 'os_access_directories.dart';
part 'os_access_defaults.dart';

/// Upstream's memory filesystem and host OS defaults, callable as an OsHandler.
///
/// The namespace has no mounts or filesystem budgets. Compose this handler to
/// customize individual operations. Seeded paths retain `..` and double roots.
final class OSAccess {
  /// Seeds files and environment; relative file paths use [rootDir].
  OSAccess({
    List<AbstractFile>? files,
    Map<String, String>? environ,
    String rootDir = '/',
    int maxUrandomBytes = 1048576,
    Duration? maxSleep = const Duration(seconds: 10),
  }) : files = List.of(files ?? const []),
       environ = environ == null || environ.isEmpty ? {} : environ,
       _defaults = _OsAccessDefaults(maxUrandomBytes, maxSleep),
       _tree = _OsAccessTree() {
    _tree.seed(this.files, _rootDir(rootDir));
  }

  /// A copy of the seed list, extended when Python creates a file.
  final List<AbstractFile> files;

  /// A nonempty supplied map is retained by reference; an empty map is copied.
  final Map<String, String> environ;
  final _OsAccessTree _tree;
  final _OsAccessDefaults _defaults;

  /// Dispatches an OS call; unknown names throw OsCallNotHandledException.
  FutureOr<MontyValue> call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    if (name == 'os.environ') {
      return MontyDict([
        for (final e in environ.entries)
          (MontyString(e.key), MontyString(e.value)),
      ]);
    }
    if (name == 'os.getenv') {
      final key = _string(args.firstOrNull);
      final value = environ[key];

      return value == null
          ? args.elementAtOrNull(1) ?? const MontyNone()
          : MontyString(value);
    }
    if (_fileCalls.contains(name)) {
      return _dispatchFile(_tree, files, name, args, kwargs);
    }

    return _defaults.call(name, args);
  }

  @override
  String toString() {
    final entries = environ.entries.map(
      (e) => '${pythonRepr(e.key)}: ${pythonRepr(e.value)}',
    );

    return 'OSAccess(files=$files, environ={${entries.join(', ')}})';
  }
}

const _fileCalls = {
  'open',
  'Path.exists',
  'Path.is_file',
  'Path.is_dir',
  'Path.is_symlink',
  'Path.read_text',
  'Path.read_bytes',
  'Path.write_text',
  'Path.write_bytes',
  'Path.append_text',
  'Path.append_bytes',
  'Path.mkdir',
  'Path.unlink',
  'Path.rmdir',
  'Path.iterdir',
  'Path.stat',
  'Path.rename',
  'Path.resolve',
  'Path.absolute',
};

String _rootDir(String path) {
  final root = purePosixPath(path);
  if (!root.startsWith('/')) {
    throw ArgumentError('Root directory must be absolute, got $root');
  }

  return root;
}

const _queryCalls = {
  'Path.exists',
  'Path.is_file',
  'Path.is_dir',
  'Path.is_symlink',
  'Path.resolve',
  'Path.absolute',
};

MontyValue _dispatchFile(
  _OsAccessTree tree,
  List<AbstractFile> createdFiles,
  String op,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final path = _path(args.firstOrNull);
  final data = args.elementAtOrNull(1);
  if (_queryCalls.contains(op)) return _pathQuery(tree, op, path);
  if (op == 'open') {
    return _resolveOpenCall(
      tree,
      createdFiles,
      path,
      data == null ? 'r' : _string(data),
    );
  }

  return _readWrite(tree, createdFiles, op, path, data, kwargs);
}

MontyValue _pathQuery(_OsAccessTree tree, String op, String path) =>
    switch (op) {
      'Path.exists' => MontyBool(tree.lookup(path) != null),
      'Path.is_file' => MontyBool(tree.lookup(path) is AbstractFile),
      'Path.is_dir' => MontyBool(tree.lookup(path) is _Directory),
      'Path.is_symlink' => const MontyBool(false),
      _ => MontyString(path.startsWith('/') ? path : purePosixPath('/$path')),
    };

MontyValue _readWrite(
  _OsAccessTree tree,
  List<AbstractFile> createdFiles,
  String op,
  String path,
  MontyValue? data,
  Map<String, MontyValue> kwargs,
) {
  final files = _OsAccessFiles(tree, createdFiles);

  return switch (op) {
    'Path.read_text' => MontyString(_text(tree.file(path).readContent())),
    'Path.read_bytes' => MontyBytes(_bytes(tree.file(path).readContent())),
    'Path.write_text' => files.write(path, _string(data)),
    'Path.write_bytes' => files.write(path, _payloadBytes(data)),
    'Path.append_text' => files.append(path, _string(data)),
    'Path.append_bytes' => files.append(path, _payloadBytes(data)),
    'Path.stat' => files.stat(path),
    'Path.unlink' => files.unlink(path),
    _ => _directoryCall(tree, op, path, data, kwargs),
  };
}

MontyValue _directoryCall(
  _OsAccessTree tree,
  String op,
  String path,
  MontyValue? data,
  Map<String, MontyValue> kwargs,
) {
  final dirs = _OsAccessDirectories(tree);

  return switch (op) {
    'Path.mkdir' => dirs.mkdir(
      path,
      parents: kwargs['parents'] == const MontyBool(true),
      existOk: kwargs['exist_ok'] == const MontyBool(true),
    ),
    'Path.rmdir' => dirs.rmdir(path),
    'Path.iterdir' => dirs.iterdir(path),
    'Path.rename' => dirs.rename(path, _path(data)),
    _ => throw const OsCallNotHandledException(),
  };
}

// The old public open helper is now private and owns its filesystem effects.
MontyFileHandle _resolveOpenCall(
  _OsAccessTree tree,
  List<AbstractFile> createdFiles,
  String path,
  String mode,
) {
  final parsed = parseFileMode(mode);
  final canonical =
      parsed.canonical ??
      (throw ExternalException('ValueError', parsed.error ?? mode));
  final handle = MontyFileHandle(path, canonical);
  final entry = tree.lookup(path);
  if (canonical.startsWith('r')) {
    tree.file(path);
  } else if (canonical.startsWith('w') || entry == null) {
    final empty = canonical.contains('b') ? Uint8List(0) : '';
    _OsAccessFiles(tree, createdFiles).write(path, empty);
  } else if (entry is _Directory) {
    throw _fsError('IsADirectoryError', path);
  }

  return handle;
}

String _path(MontyValue? arg) => purePosixPath(switch (arg) {
  MontyPath(:final value) || MontyString(:final value) => value,
  MontyFileHandle(:final path) => path,
  _ => throw const ExternalException('TypeError', 'expected a path'),
});
String _string(MontyValue? arg) => switch (arg) {
  MontyString(:final value) => value,
  _ => throw const ExternalException('TypeError', 'expected a str'),
};
Uint8List _payloadBytes(MontyValue? arg) => switch (arg) {
  MontyBytes(:final value) => Uint8List.fromList(value),
  _ => throw const ExternalException('TypeError', 'expected bytes'),
};
