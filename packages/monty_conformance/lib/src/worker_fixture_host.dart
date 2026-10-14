// The host half of upstream's datatest harness, ported for the worker engine.
//
// The reference is `crates/monty-datatest/src/main.rs` at the pinned tag
// (tool/upstream/upstream-pin.json): `dispatch_external_call`,
// `dispatch_method_call`, `dispatch_instance_attr`, `dispatch_os_call` with its
// virtual filesystem, and `create_mount_fs_tempdir`. A `# call-external`
// fixture tests the host/sandbox round trip, so it only means anything against
// the host upstream wrote it for; each function below names its Rust original.
//
// It speaks the worker's value types (`MontyValue`) and nothing else, so the
// same code runs on the VM and in a browser. It does not use the old engine's
// `fixture_externals.dart` / `fixture_os_handler.dart`, which model monty
// 0.0.23's harness and go with that engine.

// The worker's ExternalException and the host-object wrappers are internal
// to dart_monty_core until the cutover exports them.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;

/// The host functions a `# call-external` fixture may name (the arms of
/// upstream's `dispatch_external_call` and the names its lookup resolves to
/// callable functions).
const workerFixtureFunctions = <String>{
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
  'raise_error',
  'make_point',
  'make_mutable_point',
  'make_user',
  'make_empty',
  'async_call',
  'async_fail',
};

/// The constants upstream's name lookup resolves (`run_iter_loop`'s
/// `NameLookup` arm).
const Map<String, MontyValue> workerFixtureConstants = {
  'CONST_INT': MontyInt(42),
  'CONST_STR': MontyString('hello'),
  'CONST_FLOAT': MontyFloat(3.14),
  'CONST_BOOL': MontyBool(true),
  'CONST_LIST': MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
  'CONST_NONE': MontyNone(),
};

/// What one host function call answers: a value, an exception, or a pending
/// future to be settled later (upstream's `DispatchResult`).
sealed class HostOutcome {
  const HostOutcome();
}

/// The call returns [value].
final class HostReturn extends HostOutcome {
  /// Creates a [HostReturn].
  const HostReturn(this.value);

  /// The value: a [MontyValue], or a registered instance's wrapper.
  final Object value;
}

/// The call raises [excType] with [message].
final class HostRaise extends HostOutcome {
  /// Creates a [HostRaise].
  const HostRaise(this.excType, this.message);

  /// The exception type name.
  final String excType;

  /// The message.
  final String message;
}

/// The call is a coroutine: the sandbox gets a pending future, settled later
/// with [settled] (a [HostReturn] or a [HostRaise]).
final class HostPending extends HostOutcome {
  /// Creates a [HostPending].
  const HostPending(this.settled);

  /// How the future settles.
  final HostOutcome settled;
}

/// One registered host instance: its class identity and eager attributes
/// (upstream's `Fixture`).
final class _Fixture {
  const _Fixture(this.className, this.typeId, this.attrs);

  final String className;
  final int typeId;
  final Map<String, MontyValue> attrs;

  int intAttr(String name) {
    final value = attrs[name];
    if (value is! MontyInt) throw StateError("'$name' must be int");

    return value.value;
  }
}

/// One host class per fixture class name.
final Map<String, HostClass<_Fixture>> _fixtureClasses = {};

/// A fixture's members: its attributes, and the properties
/// `dispatch_instance_attr` serves (`dimensions` on the points, `boom`,
/// which raises `KeyError` on the host, on `MutablePoint`). Any other name
/// is absent (an `AttributeError`).
final HostMembers<_Fixture> _fixtureMembers = HostMembers(
  fields: {
    for (final name in ['x', 'y', 'name', 'active'])
      name: (f) => f.attrs[name] ?? (throw _absent(f, name)),
  },
  properties: {
    'dimensions': (f) => f.className == 'Point' || f.className == 'MutablePoint'
        ? const MontyInt(2)
        : throw _absent(f, 'dimensions'),
    'boom': (f) => f.className == 'MutablePoint'
        ? throw const ExternalException('KeyError', 'boom')
        : throw _absent(f, 'boom'),
  },
);

ExternalException _absent(_Fixture f, String name) => ExternalException(
  'AttributeError',
  "'${f.className}' object has no attribute '$name'",
);

/// A canonical uuid string for `MontyUuid::from_u128(n)`.
String _uuid(int n) {
  final hex = n.toRadixString(16).padLeft(32, '0');

  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The host-side store of class instances handed to the sandbox, keyed by
/// instance id, and the dispatch over it (upstream's `FixtureRegistry`,
/// `dispatch_external_call`, `dispatch_method_call` and
/// `dispatch_instance_attr`).
///
/// Ids are deterministic, as upstream's are, so expected output is
/// reproducible. Registered instances are snapshots: a sandbox-side `setattr`
/// changes the sandbox copy only.
final class WorkerFixtureRegistry {
  int _next = 1;
  final Map<String, _Fixture> _instances = {};

  /// [fixture] as the sandbox receives it: a host object whose fields
  /// cross eagerly and whose properties the session answers lazily
  /// (`dispatch_instance_attr`) through the wrapper.
  Object _register(_Fixture fixture) {
    final instanceId = _uuid(0x1000 + _next);
    _next++;
    _instances[instanceId] = fixture;

    return ClassInstance(
      fixture,
      classType: ClassType(
        _fixtureClasses.putIfAbsent(fixture.className, () {
          return HostClass<_Fixture>(
            fixture.className,
            isDataclass: true,
            instance: _fixtureMembers,
          );
        }),
        id: _uuid(fixture.typeId),
      ),
      id: instanceId,
      policies: HostPolicies(
        eagerAttrs: fixture.attrs.keys.toList(),
        lazyAttrs: 'all',
      ),
    );
  }

  Object _point(int x, int y) =>
      _register(_Fixture('Point', 1, {'x': MontyInt(x), 'y': MontyInt(y)}));

  /// `dispatch_external_call`.
  HostOutcome call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    void arity(int n) {
      if (args.length != n) {
        throw StateError('$name requires $n argument(s)');
      }
    }

    String str(int i) {
      final v = args[i];
      if (v is! MontyString) throw StateError('$name: arg $i must be str');

      return v.value;
    }

    int integer(int i) {
      final v = args[i];
      if (v is! MontyInt) throw StateError('$name: arg $i must be int');

      return v.value;
    }

    String excType(int i) {
      final t = str(i);
      const known = {'ValueError', 'TypeError', 'KeyError', 'RuntimeError'};
      if (!known.contains(t)) {
        throw StateError('$name: unsupported exception type: $t');
      }

      return t;
    }

    switch (name) {
      case 'add_ints':
        arity(2);

        return HostReturn(MontyInt(integer(0) + integer(1)));
      case 'concat_strings':
        arity(2);

        return HostReturn(MontyString(str(0) + str(1)));
      case 'return_value':
        arity(1);

        return HostReturn(args.first);
      case 'get_list':
        arity(0);

        return const HostReturn(
          MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
        );
      case 'raise_error':
        arity(2);

        return HostRaise(excType(0), str(1));
      case 'make_point':
        arity(0);

        return HostReturn(_point(1, 2));
      case 'make_mutable_point':
        arity(0);

        return HostReturn(
          _register(
            const _Fixture('MutablePoint', 2, {
              'x': MontyInt(1),
              'y': MontyInt(2),
            }),
          ),
        );
      case 'make_user':
        arity(1);

        return HostReturn(
          _register(
            _Fixture('User', 3, {
              'name': MontyString(str(0)),
              'active': const MontyBool(true),
            }),
          ),
        );
      case 'make_empty':
        arity(0);

        return HostReturn(_register(const _Fixture('Empty', 4, {})));
      case 'async_call':
        arity(1);

        return HostPending(HostReturn(args.first));
      case 'async_fail':
        arity(2);

        return HostPending(HostRaise(excType(0), str(1)));
    }
    throw StateError('Unknown external function: $name');
  }

  /// `dispatch_method_call`: a method call routed by the receiver's id.
  HostOutcome method(
    String method,
    String instanceId,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    final fixture = _instances[instanceId.toLowerCase()];
    if (fixture == null) {
      return HostRaise(
        'RuntimeError',
        "no host object registered for method call '$method' "
            '(id ${instanceId.toLowerCase()})',
      );
    }
    final cls = fixture.className;
    final isPoint = cls == 'Point';

    if ((isPoint || cls == 'MutablePoint') && method == 'sum') {
      return HostReturn(MontyInt(fixture.intAttr('x') + fixture.intAttr('y')));
    }
    if (isPoint && method == 'add') {
      if (args.length != 2) throw StateError('Point.add requires dx, dy');

      return HostReturn(
        _point(
          fixture.intAttr('x') + (args[0] as MontyInt).value,
          fixture.intAttr('y') + (args[1] as MontyInt).value,
        ),
      );
    }
    if (isPoint && method == 'scale') {
      if (args.length != 1) throw StateError('Point.scale requires factor');
      final factor = (args[0] as MontyInt).value;

      return HostReturn(
        _point(fixture.intAttr('x') * factor, fixture.intAttr('y') * factor),
      );
    }
    if (isPoint && method == 'describe') {
      final label = args.isNotEmpty
          ? (args[0] as MontyString).value
          : switch (kwargs['label']) {
              MontyString(:final value) => value,
              _ => 'point',
            };

      return HostReturn(
        MontyString('$label(${fixture.intAttr('x')}, ${fixture.intAttr('y')})'),
      );
    }
    if (cls == 'MutablePoint' && method == 'shift') {
      return const HostReturn(MontyNone());
    }
    if (cls == 'User' && method == 'greeting') {
      final name = (fixture.attrs['name']! as MontyString).value;

      return HostReturn(MontyString('Hello, $name!'));
    }

    return HostRaise(
      'AttributeError',
      "'$cls' object has no attribute '$method'",
    );
  }
}

// ---------------------------------------------------------------------------
// The OS handler
// ---------------------------------------------------------------------------

/// `VFS_MTIME`.
const double _mtime = 1700000000;

const _statFields = <String>[
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
];

MontyValue _statResult(int mode, int nlink, int size) => MontyNamedTuple(
  typeName: 'StatResult',
  fieldNames: _statFields,
  values: [
    MontyInt(mode),
    const MontyInt(0),
    const MontyInt(0),
    MontyInt(nlink),
    const MontyInt(0),
    const MontyInt(0),
    MontyInt(size),
    const MontyFloat(_mtime),
    const MontyFloat(_mtime),
    const MontyFloat(_mtime),
  ],
);

/// `file_stat`: type bits added to a bare permission mode.
MontyValue _fileStat(int mode, int size) =>
    _statResult(mode < 0x200 ? mode | 32768 : mode, 1, size);

/// `dir_stat`.
MontyValue _dirStat(int mode) =>
    _statResult(mode < 0x200 ? mode | 16384 : mode, 2, 4096);

ExternalException _errno(String type, int errno, String text, String path) =>
    ExternalException(type, '[Errno $errno] $text: ${_pyRepr(path)}');

ExternalException _notFound(String path) =>
    _errno('FileNotFoundError', 2, 'No such file or directory', path);

String _pyRepr(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

String? _parent(String path) {
  final i = path.lastIndexOf('/');
  if (i < 0) return null;

  return i == 0 ? (path == '/' ? null : '/') : path.substring(0, i);
}

/// The environment upstream's handler reports.
const Map<String, String> _env = {
  'VIRTUAL_HOME': '/virtual/home',
  'VIRTUAL_USER': 'testuser',
  'VIRTUAL_EMPTY': '',
};

/// An in-memory filesystem answering the OS calls a fixture makes.
///
/// [WorkerFixtureOs.virtual] is upstream's `/virtual` tree with its mutable
/// layer (`MUTABLE_VFS`, `dispatch_os_call`); [WorkerFixtureOs.mounted] is the
/// tree `create_mount_fs_tempdir` writes, which upstream serves from a real
/// temporary directory mounted at `/mnt`. A fresh instance per fixture, as
/// upstream resets its mutable layer per test.
final class WorkerFixtureOs {
  WorkerFixtureOs._(this._files, this._dirs, {this.real = false});

  /// The `/virtual` tree.
  factory WorkerFixtureOs.virtual() => WorkerFixtureOs._(
    {
      '/virtual/file.txt': (_utf8('hello world\n'), 0x1a4),
      '/virtual/data.bin': (Uint8List.fromList([0, 1, 2, 3]), 0x1a4),
      '/virtual/empty.txt': (Uint8List(0), 0x1a4),
      '/virtual/subdir/nested.txt': (_utf8('nested content'), 0x1a4),
      '/virtual/subdir/deep/file.txt': (_utf8('deep'), 0x1a4),
      '/virtual/readonly.txt': (_utf8('readonly'), 0x124),
    },
    {'/virtual', '/virtual/subdir', '/virtual/subdir/deep'},
  );

  /// The tree `create_mount_fs_tempdir` writes, under `/mnt`.
  factory WorkerFixtureOs.mounted() => WorkerFixtureOs._(
    {
      '/mnt/hello.txt': (_utf8('hello world\n'), 0x1a4),
      '/mnt/empty.txt': (Uint8List(0), 0x1a4),
      '/mnt/data.bin': (Uint8List.fromList([0, 1, 2, 3]), 0x1a4),
      '/mnt/subdir/nested.txt': (_utf8('nested content'), 0x1a4),
      '/mnt/subdir/deep/file.txt': (_utf8('deep file'), 0x1a4),
      '/mnt/readonly.txt': (_utf8('readonly content'), 0x1a4),
    },
    {'/mnt', '/mnt/subdir', '/mnt/subdir/deep'},
    real: true,
  );

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  final Map<String, (Uint8List, int)> _files;
  final Set<String> _dirs;

  /// Whether this stands for a real mounted directory rather than upstream's
  /// virtual tree: a write needs its parent directory, and a text write
  /// reports characters.
  final bool real;

  bool _isDir(String p) => _dirs.contains(p);

  /// An `OsHandler`: a call it does not model is declined.
  FutureOr<MontyValue> call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    String path(int i) {
      final p = (args[i] as MontyPath).value;
      _checkName(p);

      return p;
    }

    switch (name) {
      case 'system.sleep' || 'system.async_sleep':
        // The sandbox has already capped the delay (`thread::sleep`).
        final seconds = (args.first as MontyFloat).value;

        return Future<MontyValue>.delayed(
          Duration(microseconds: (seconds * 1e6).round()),
          () => const MontyNone(),
        );
      case 'os.urandom':
        final size = (args.first as MontyInt).value;

        return MontyBytes(
          Uint8List.fromList([for (var i = 0; i < size; i++) i % 256]),
        );
      case 'os.environ':
        return MontyDict.ofStrings({
          for (final e in _env.entries) e.key: MontyString(e.value),
        });
      case 'os.getenv':
        final key = (args[0] as MontyString).value;
        final value = _env[key];

        return value == null ? args[1] : MontyString(value);
      case 'Path.exists':
        final p = path(0);

        return MontyBool(_files.containsKey(p) || _isDir(p));
      case 'Path.is_file':
        return MontyBool(_files.containsKey(path(0)));
      case 'Path.is_dir':
        return MontyBool(_isDir(path(0)));
      case 'Path.is_symlink':
        return const MontyBool(false);
      case 'Path.read_text':
        final p = path(0);
        final file = _files[p];
        if (file == null) throw _noFile(p);
        try {
          return MontyString(utf8.decode(file.$1));
        } on FormatException catch (e) {
          throw ExternalException(
            'UnicodeDecodeError',
            _decodeMessage(file.$1, e.offset),
          );
        }
      case 'Path.read_bytes':
        final p = path(0);
        final file = _files[p];
        if (file == null) throw _noFile(p);

        return MontyBytes(Uint8List.fromList(file.$1));
      case 'Path.stat':
        final p = path(0);
        final file = _files[p];
        if (file != null) return _fileStat(file.$2, file.$1.length);
        if (_isDir(p)) return _dirStat(0x1ed);
        throw _notFound(p);
      case 'Path.iterdir':
        final p = path(0);
        if (real && _files.containsKey(p)) {
          throw _errno('NotADirectoryError', 20, 'Not a directory', p);
        }
        if (!_isDir(p)) throw _notFound(p);
        final entries = <String>{
          for (final f in _files.keys)
            if (_parent(f) == p) f,
          for (final d in _dirs)
            if (_parent(d) == p) d,
        };

        return MontyList([for (final e in entries) MontyPath(e)]);
      case 'Path.resolve' || 'Path.absolute':
        return real ? MontyPath(path(0)) : MontyString(path(0));
      case 'open':
        return _open(path(0), (args[1] as MontyString).value);
      case 'Path.write_text':
        final text = (args[1] as MontyString).value;
        final bytes = _utf8(text);
        _needParent(path(0));
        _files[path(0)] = (bytes, 0x1a4);

        return MontyInt(real ? text.runes.length : bytes.length);
      case 'Path.write_bytes':
        final bytes = Uint8List.fromList((args[1] as MontyBytes).value);
        _needParent(path(0));
        _files[path(0)] = (bytes, 0x1a4);

        return MontyInt(bytes.length);
      case 'Path.append_text':
        final text = (args[1] as MontyString).value;
        _needParent(path(0));
        _append(path(0), _utf8(text));

        return MontyInt(text.runes.length);
      case 'Path.append_bytes':
        final bytes = (args[1] as MontyBytes).value;
        _needParent(path(0));
        _append(path(0), Uint8List.fromList(bytes));

        return MontyInt(bytes.length);
      case 'Path.mkdir':
        return _mkdir(
          path(0),
          parents: (kwargs['parents'] as MontyBool?)?.value ?? false,
          existOk: (kwargs['exist_ok'] as MontyBool?)?.value ?? false,
        );
      case 'Path.unlink':
        final p = path(0);
        if (real && _isDir(p)) {
          throw _errno('IsADirectoryError', 21, 'Is a directory', p);
        }
        if (_files.remove(p) == null) throw _notFound(p);

        return const MontyNone();
      case 'Path.rmdir':
        final p = path(0);
        if (real && _files.containsKey(p)) {
          throw _errno('NotADirectoryError', 20, 'Not a directory', p);
        }
        if (!_isDir(p)) throw _notFound(p);
        if (real && _children(p).isNotEmpty) {
          throw _errno('OSError', 39, 'Directory not empty', p);
        }
        _dirs.remove(p);

        return const MontyNone();
      case 'Path.rename':
        return _rename(path(0), path(1));
    }

    throw const OsCallNotHandledException();
  }

  /// The paths directly inside directory [p].
  Set<String> _children(String p) => {
    for (final f in _files.keys)
      if (_parent(f) == p) f,
    for (final d in _dirs)
      if (_parent(d) == p) d,
  };

  MontyValue _rename(String src, String dst) {
    final file = _files[src];
    if (file != null) {
      if (real && _isDir(dst)) {
        throw _errno('IsADirectoryError', 21, 'Is a directory', dst);
      }
      _files
        ..remove(src)
        ..[dst] = file;

      return const MontyNone();
    }
    if (!_isDir(src)) throw _notFound(src);
    if (real) {
      if (_files.containsKey(dst)) {
        throw _errno('NotADirectoryError', 20, 'Not a directory', dst);
      }
      if (_isDir(dst) && _children(dst).isNotEmpty) {
        throw _errno('OSError', 39, 'Directory not empty', dst);
      }
    }
    final prefix = '$src/';
    String moved(String p) =>
        p == src ? dst : '$dst/${p.substring(prefix.length)}';
    final files = {
      for (final e in _files.entries)
        if (real && e.key.startsWith(prefix)) e.key: e.value,
    };
    final dirs = [
      for (final d in _dirs)
        if (d == src || (real && d.startsWith(prefix))) d,
    ];
    for (final entry in files.entries) {
      _files
        ..remove(entry.key)
        ..[moved(entry.key)] = entry.value;
    }
    _dirs
      ..removeAll(dirs)
      ..addAll(dirs.map(moved));

    return const MontyNone();
  }

  /// CPython's `UnicodeDecodeError` text for the byte at [offset] that
  /// UTF-8 refused: upstream's virtual tree gives the generic text, a real
  /// directory the byte and its position.
  String _decodeMessage(Uint8List bytes, int? offset) {
    if (!real || offset == null || offset >= bytes.length) {
      return "'utf-8' codec can't decode bytes";
    }
    final byte = bytes[offset].toRadixString(16).padLeft(2, '0');

    return "'utf-8' codec can't decode byte 0x$byte in position $offset: "
        'invalid start byte';
  }

  /// A real filesystem refuses a component over 255 bytes or a path over
  /// 4096 (`ENAMETOOLONG`).
  void _checkName(String p) {
    if (!real) return;
    final tooLong =
        utf8.encode(p).length > 4096 ||
        p.split('/').any((c) => utf8.encode(c).length > 255);
    if (tooLong) throw _errno('OSError', 36, 'File name too long', p);
  }

  /// Why a read of [p] found no file: it is a directory, or absent.
  ExternalException _noFile(String p) => real && _isDir(p)
      ? _errno('IsADirectoryError', 21, 'Is a directory', p)
      : _notFound(p);

  /// A real directory refuses a write whose parent is missing, or whose
  /// target is a directory.
  void _needParent(String p) {
    if (real && _isDir(p)) {
      throw _errno('IsADirectoryError', 21, 'Is a directory', p);
    }
    final parent = _parent(p);
    if (real && parent != null && !_isDir(parent)) throw _notFound(p);
  }

  MontyValue _open(String p, String mode) {
    switch (mode.isEmpty ? 'r' : mode[0]) {
      case 'r':
        if (!_files.containsKey(p)) {
          throw _isDir(p)
              ? _errno('IsADirectoryError', 21, 'Is a directory', p)
              : _notFound(p);
        }
      case 'w':
        _needParent(p);
        _files[p] = (Uint8List(0), 0x1a4);
      default:
        _needParent(p);
        _files.putIfAbsent(p, () => (Uint8List(0), 0x1a4));
    }

    return MontyFileHandle(path: p, mode: mode);
  }

  void _append(String p, Uint8List more) {
    final old = _files[p];
    final bytes = BytesBuilder(copy: false)
      ..add(old?.$1 ?? Uint8List(0))
      ..add(more);
    _files[p] = (bytes.takeBytes(), old?.$2 ?? 0x1a4);
  }

  MontyValue _mkdir(String p, {required bool parents, required bool existOk}) {
    if (real && _files.containsKey(p)) {
      throw _errno('FileExistsError', 17, 'File exists', p);
    }
    if (_isDir(p)) {
      if (existOk) return const MontyNone();
      throw _errno('FileExistsError', 17, 'File exists', p);
    }
    final parent = _parent(p);
    if (parent != null && !_isDir(parent)) {
      if (!parents) throw _notFound(p);
      _createParents(parent);
    }
    _dirs.add(p);

    return const MontyNone();
  }

  void _createParents(String p) {
    if (_isDir(p)) return;
    if (real && _files.containsKey(p)) {
      throw _errno('NotADirectoryError', 20, 'Not a directory', p);
    }
    final parent = _parent(p);
    if (parent != null) _createParents(parent);
    _dirs.add(p);
  }
}
