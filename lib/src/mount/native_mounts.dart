/// Host mount roots and per-feed tables backed by upstream monty-fs.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_monty_core/src/mount/native_mount_bindings.dart';
import 'package:dart_monty_core/src/mount/native_mount_lookup.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:ffi/ffi.dart';

NativeMountBindings get _bindings => nativeMountLookup.bindings;
NativeMounts get _mounts => NativeMounts(_bindings);

/// Which discovery route supplied the symbols (for packaging smoke tests).
String get nativeMountLookupRoute => _bindings.route;

/// Owns the native bindings used while constructing directory capabilities.
final class NativeMounts {
  /// Uses the supplied ABI for acquisition and cleanup of every opened root.
  const NativeMounts(this.bindings);

  /// Resolved native mount ABI.
  final NativeMountBindings bindings;

  /// Opens and validates a capability, releasing it if decoding fails.
  NativeMountRoot openRoot({
    required String hostPath,
    required String virtualPath,
    String mode = 'overlay',
    int? writeBytesLimit,
    int memoryUsageLimit = 100000000,
  }) {
    if (writeBytesLimit != null && writeBytesLimit < 0) {
      throw RangeError.range(writeBytesLimit, 0, null, 'writeBytesLimit');
    }
    if (memoryUsageLimit < 0) {
      throw RangeError.range(memoryUsageLimit, 0, null, 'memoryUsageLimit');
    }

    return using((arena) {
      final id = bindings.open(
        _string(arena, virtualPath),
        _string(arena, hostPath),
        _string(arena, mode),
        writeBytesLimit ?? -1,
        memoryUsageLimit,
      );
      if (id < 0) {
        final message = _lastError(bindings);
        final (name, value) = switch (message) {
          final text when text.startsWith('Invalid mode') => ('mode', mode),
          final text when text.startsWith('virtual path') => (
            'virtualPath',
            virtualPath,
          ),
          _ => ('hostPath', hostPath),
        };
        throw ArgumentError.value(value, name, message);
      }
      try {
        return _readRoot(bindings, arena, id);
      } catch (_) {
        bindings.release(Pointer.fromAddress(id));
        rethrow;
      }
    });
  }
}

/// An opened directory capability, used only by the creating isolate.
final class NativeMountRoot implements Finalizable {
  /// Opens and validates the capability immediately, using upstream's rules.
  factory NativeMountRoot({
    required String hostPath,
    required String virtualPath,
    String mode = 'overlay',
    int? writeBytesLimit,
    int memoryUsageLimit = 100000000,
  }) => _mounts.openRoot(
    hostPath: hostPath,
    virtualPath: virtualPath,
    mode: mode,
    writeBytesLimit: writeBytesLimit,
    memoryUsageLimit: memoryUsageLimit,
  );

  NativeMountRoot._(
    this._serviceBindings,
    this._id,
    this.hostPath,
    this.virtualPath,
  ) {
    _serviceBindings.finalizer.attach(
      this,
      Pointer.fromAddress(_id),
      detach: this,
    );
  }

  /// Canonical path of the opened host directory, retained after close.
  final String hostPath;

  /// Normalised absolute virtual path, retained after close.
  final String virtualPath;

  final NativeMountBindings _serviceBindings;
  final int _id;
  bool _closed = false;

  /// Releases this root; tables already built retain their own capability.
  void close() {
    if (_closed) return;
    _serviceBindings.close(_id);
    // Keep the finalizer attached: it releases the native closed-root label
    // on collection. close() releases the directory descriptor immediately.
    _closed = true;
  }
}

/// One feed's overlay and budgets. The feed owner must close it in finally.
final class NativeMountTable {
  /// Builds a fresh table, checking closed roots and overlap before execution.
  factory NativeMountTable(List<NativeMountRoot> roots) {
    for (final root in roots) {
      if (root._closed) {
        throw StateError("mount '${root.virtualPath}' is closed");
      }
    }

    return using((arena) {
      // A list is not Finalizable: keep every root alive until Rust has cloned
      // its capability, even when the caller supplied a temporary list.
      final lease = _RootLease(roots);
      final ids = arena<Int64>(roots.isEmpty ? 1 : roots.length);
      for (final (index, root) in lease.roots.indexed) {
        ids[index] = root._id;
      }
      final id = _bindings.beginFeed(ids, roots.length);
      if (id < 0) {
        throw recordError(
          RaisedRecord('ValueError', _lastError(_bindings), const []),
        );
      }

      return NativeMountTable._(id);
    });
  }

  NativeMountTable._(this._id);
  final int _id;
  bool _closed = false;

  /// Services an OsCall protobuf. Null means not handled; otherwise ResumeCall.
  Uint8List? call(List<int> bytes) {
    if (_closed) throw StateError('mount table is closed');

    return using((arena) {
      final input = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      input.asTypedList(bytes.length).setAll(0, bytes);

      return _output(
        arena,
        (out, length) => _bindings.call(_id, input, bytes.length, out, length),
        _bindings,
      );
    });
  }

  /// Discards the table and all overlay data. Idempotent.
  void close() {
    if (_closed) return;
    _bindings.endFeed(_id);
    _closed = true;
  }
}

NativeMountRoot _readRoot(NativeMountBindings bindings, Arena arena, int id) {
  final info =
      _output(
        arena,
        (out, length) => bindings.rootInfo(id, out, length),
        bindings,
      ) ??
      (throw StateError('native root info was not handled'));
  // Only the host delimiter is structural; virtual labels may contain NUL.
  final split = info.indexOf(0);

  return NativeMountRoot._(
    bindings,
    id,
    utf8.decode(info.sublist(0, split)),
    utf8.decode(info.sublist(split + 1)),
  );
}

String _lastError(NativeMountBindings bindings) {
  final message = bindings.lastError().ref;

  return utf8.decode(message.data.asTypedList(message.length));
}

Pointer<MountString> _string(Arena arena, String value) {
  final bytes = utf8.encode(value);
  final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  final view = arena<MountString>();
  view.ref
    ..data = data
    ..length = bytes.length;

  return view;
}

Uint8List? _output(
  Arena arena,
  int Function(Pointer<Pointer<Uint8>>, Pointer<UintPtr>) operation,
  NativeMountBindings bindings,
) {
  final out = arena<Pointer<Uint8>>();
  final length = arena<UintPtr>();
  final status = operation(out, length);
  if (status < 0) throw FormatException(_lastError(bindings));
  if (status == 0) return null;
  try {
    return Uint8List.fromList(out.value.asTypedList(length.value));
  } finally {
    bindings.free(out.value, length.value);
  }
}

// Finalizable keeps its fields reachable through the entire lexical scope.
final class _RootLease implements Finalizable {
  const _RootLease(this.roots);
  final List<NativeMountRoot> roots;
}
