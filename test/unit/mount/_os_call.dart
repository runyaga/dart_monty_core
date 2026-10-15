// Calls an `OsHandler` the way the worker calls it, from plain Dart values.
//
// The mount suites were written against a handler that took and returned
// Dart objects. The handler now takes and returns `MontyValue`s, as the
// worker sends and reads them (`osCallParts` in host_answers.dart): a path is
// a `MontyPath`, a payload a `MontyString` or `MontyBytes`, an open mode a
// `MontyString` and a `mkdir` flag a `MontyBool` keyword. This adapter does
// that wrapping in one place and unwraps the scalar answers, so each suite
// keeps asserting what it asserted. memory_mounted_os_handler_test.dart pins
// the MontyValue answers themselves, without the adapter.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart' show OsHandler;

/// An OS handler called with, and answering, plain Dart values.
typedef DartOsCall =
    FutureOr<Object?> Function(
      String op,
      List<Object?> args,
      Map<String, Object?>? kwargs,
    );

/// [memoryMountedOsHandler] over [mounts] and [files], called through
/// [dartCalls].
DartOsCall mountedHandler({
  required List<MountDir> mounts,
  required List<VfsFile> files,
  OsHandler? fallthrough,
}) => dartCalls(
  memoryMountedOsHandler(
    mounts: mounts,
    files: files,
    fallthrough: fallthrough,
  ),
);

/// [handler] called with Dart arguments wrapped as the worker wraps them,
/// its answer unwrapped: a bool, int, str or `None` as its Dart value, a list
/// as its items, anything else as the [MontyValue] it is. A throw, a
/// synchronous one included, propagates unchanged.
DartOsCall dartCalls(OsHandler handler) => (op, args, kwargs) {
  final answer = handler(
    op,
    [for (final (i, a) in args.indexed) _arg(op, i, a)],
    {
      for (final MapEntry(:key, :value) in (kwargs ?? const {}).entries)
        key: _arg(op, -1, value),
    },
  );

  return answer is Future<MontyValue> ? _unwrapLater(answer) : _unwrap(answer);
};

/// [a] as the worker sends argument [i] of [op]: a path, the first argument
/// and a rename's destination, as a [MontyPath].
MontyValue _arg(String op, int i, Object? a) => switch (a) {
  final MontyValue v => v,
  final String s when i == 0 || (op == 'Path.rename' && i == 1) => MontyPath(
    s,
  ),
  final String s => MontyString(s),
  final List<int> bytes => MontyBytes(Uint8List.fromList(bytes)),
  _ => MontyValue.fromDart(a),
};

Future<Object?> _unwrapLater(Future<MontyValue> answer) async =>
    _unwrap(await answer);

Object? _unwrap(MontyValue v) => switch (v) {
  MontyBool(:final value) => value,
  MontyInt(:final value) => value,
  MontyString(:final value) => value,
  MontyNone() => null,
  MontyList(:final items) => items,
  _ => v,
};
