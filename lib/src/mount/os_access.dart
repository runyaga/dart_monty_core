import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:dart_monty_core/src/mount/abstract_file.dart';
import 'package:dart_monty_core/src/mount/file_content.dart';
import 'package:dart_monty_core/src/mount/memory_file.dart';
import 'package:dart_monty_core/src/mount/stat_result.dart';
import 'package:dart_monty_core/src/platform/double_text.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:dart_monty_core/src/worker/python_rules.dart';

part 'os_access_tree.dart';
part 'os_access_files.dart';
part 'os_access_directories.dart';
part 'os_access_defaults.dart';
part 'os_access_repr.dart';

/// Upstream's memory filesystem and host OS defaults, callable as an OsHandler.
///
/// The namespace has no mounts or filesystem budgets. Compose this handler to
/// customize individual operations. Seeded paths retain `..` and double roots.
/// `Path.is_symlink` returns false without reading its path argument.
/// `Path.scan` reads a subtree in one call, as upstream's does.
///
/// It is one namespace, as upstream's is: a `..` in a path stays inside it, so
/// a directory seeded under it is not a boundary between the files around it.
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
  'Path.scan',
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

/// The calls whose handler coerces a file handle with upstream's
/// `path_from_arg`: the reads, writes and appends. Every other call takes a
/// path only, except `Path.is_symlink`, which ignores its argument.
const _handleCalls = {
  'Path.read_text',
  'Path.read_bytes',
  'Path.write_text',
  'Path.write_bytes',
  'Path.append_text',
  'Path.append_bytes',
};

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
  // Upstream's `path_is_symlink` never looks at its argument.
  if (op == 'Path.is_symlink') return const MontyBool(false);
  // A scan names its root as the request spelled it, so it reads the
  // argument itself rather than the normalized path.
  if (op == 'Path.scan') return _scan(tree, args, kwargs);
  if (op == 'Path.mkdir') _checkMkdirKeywords(kwargs);
  final path = _path(args.firstOrNull, handleOk: _handleCalls.contains(op));
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
    'Path.write_text' => files.write(path, _payload(data, 'a str')),
    'Path.write_bytes' => files.write(path, _payload(data, 'bytes')),
    'Path.append_text' => files.append(path, _payload(data, 'a str')),
    'Path.append_bytes' => files.append(path, _payload(data, 'bytes')),
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
    'Path.mkdir' => _mkdir(dirs, path, kwargs),
    'Path.rmdir' => dirs.rmdir(path),
    'Path.iterdir' => dirs.iterdir(path),
    'Path.rename' => dirs.rename(path, _path(data)),
    _ => throw const OsCallNotHandledException(),
  };
}

/// Upstream's `Path.mkdir` dispatch asserts at most two keywords before it
/// looks at the path.
void _checkMkdirKeywords(Map<String, MontyValue> kwargs) {
  if (kwargs.length > 2) {
    throw ExternalException(
      'AssertionError',
      'Unexpected keyword arguments: ${_dictRepr(kwargs)}',
    );
  }
}

/// `parents` and `exist_ok` by Python truthiness.
MontyValue _mkdir(
  _OsAccessDirectories dirs,
  String path,
  Map<String, MontyValue> kwargs,
) => dirs.mkdir(
  path,
  parents: _truthy(kwargs['parents']),
  existOk: _truthy(kwargs['exist_ok']),
);

/// Resolves an `open` call and applies its filesystem effect.
///
/// Read mode requires an existing file and preserves its content. A missing
/// file raises `FileNotFoundError`, and a directory raises
/// `IsADirectoryError`. Write mode truncates or creates an empty file and
/// requires an existing parent directory, which otherwise raises
/// `FileNotFoundError`. Write and append mode raise `IsADirectoryError` for a
/// directory. Append mode preserves existing content or creates an empty file.
/// An unsupported mode raises `ValueError`.
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

String _path(MontyValue? arg, {bool handleOk = false}) =>
    purePosixPath(switch (arg) {
      MontyPath(:final value) || MontyString(:final value) => value,
      MontyFileHandle(:final path) when handleOk => path,
      MontyFileHandle() => throw const ExternalException(
        'TypeError',
        'argument should be a str or an os.PathLike object where __fspath__ '
            "returns a str, not 'MontyFileHandle'",
      ),
      _ => throw const ExternalException('TypeError', 'expected a path'),
    });

String _string(MontyValue? arg) => switch (arg) {
  MontyString(:final value) => value,
  _ => throw const ExternalException('TypeError', 'expected a str'),
};

/// A write or append payload as upstream's `_write_file` and `_append` take
/// it: text or bytes in either operation, kept as given. [expected] names
/// the type the operation was meant for, in the message for any other value.
Object _payload(MontyValue? arg, String expected) => switch (arg) {
  MontyString(:final value) => value,
  MontyBytes(:final value) => Uint8List.fromList(value),
  _ => throw ExternalException('TypeError', 'expected $expected'),
};

/// Python truthiness of a keyword value.
bool _truthy(MontyValue? arg) =>
    _scalarTruth(arg) ?? _compoundTruth(arg) ?? _collectionTruth(arg) ?? true;

bool? _scalarTruth(MontyValue? arg) => switch (arg) {
  null || MontyNone() => false,
  MontyBool(:final value) => value,
  MontyInt(:final value) => value != 0,
  MontyBigInt(:final value) => value != BigInt.zero,
  MontyFloat(:final value) => value != 0.0,
  _ => null,
};

bool? _compoundTruth(MontyValue? arg) => switch (arg) {
  MontyComplex(:final real, :final imag) => real != 0 || imag != 0,
  MontyTimeDelta(:final days, :final seconds, :final microseconds) =>
    days != 0 || seconds != 0 || microseconds != 0,
  _ => null,
};

bool? _collectionTruth(MontyValue? arg) => switch (arg) {
  MontyString(:final value) => value.isNotEmpty,
  MontyBytes(:final value) => value.isNotEmpty,
  MontyList(:final items) ||
  MontyTuple(:final items) ||
  MontySet(:final items) ||
  MontyFrozenSet(:final items) => items.isNotEmpty,
  MontyNamedTuple(:final values) => values.isNotEmpty,
  MontyDict(:final pairs) => pairs.isNotEmpty,
  _ => null,
};
