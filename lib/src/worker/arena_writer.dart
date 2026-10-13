/// Values to the worker: [MontyValue] to a monty-proto `Arena`.
///
/// The writer emits nodes in post-order (every child before its holder) and
/// each Dart object once, so an object passed in two places reaches Python
/// as one object. It walks an explicit stack, so nesting depth is bounded by
/// memory, not by the Dart call stack.
///
/// It carries the same subset `ArenaReader` decodes; anything else throws
/// [UnsupportedError].
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';

/// Builds one arena from host values.
///
/// Every [add] goes into the same arena, so an object passed in two places
/// (two inputs, or an input and one of its own elements) is one node.
final class ArenaWriter {
  /// The arena built so far; put it in the message that carries the roots.
  final pb.Arena arena = pb.Arena();

  final Map<MontyValue, int> _ids = Map.identity();

  /// Adds [value] and returns its node index.
  ///
  /// Throws [ArgumentError] for a value that contains itself (Python accepts
  /// no cycle as input) and [UnsupportedError] for a kind outside the subset.
  int add(MontyValue value) {
    final open = Set<MontyValue>.identity();
    final stack = [value];
    for (var v = stack.lastOrNull; v != null; v = stack.lastOrNull) {
      if (_ids.containsKey(v)) {
        stack.removeLast();
        continue;
      }
      final pending = [
        for (final c in _childrenOf(v))
          if (!_ids.containsKey(c)) c,
      ];
      if (pending.isEmpty) {
        _ids[v] = _emit(_node(v));
        open.remove(v);
        stack.removeLast();
        continue;
      }
      if (!open.add(v)) {
        throw ArgumentError.value(
          v,
          'value',
          'contains itself; a cycle cannot be sent to the worker',
        );
      }
      stack.addAll(pending);
    }

    return _id(value);
  }

  int _emit(pb.MontyNode node) {
    arena.nodes.add(node);
    arena.nodeCount = arena.nodes.length;

    return arena.nodes.length - 1;
  }

  int _id(MontyValue v) =>
      _ids[v] ?? (throw StateError('$v was referenced before it was added'));

  pb.MontyNode _node(MontyValue v) => _scalarNode(v) ?? _containerNode(v);

  pb.MontyNode _containerNode(MontyValue v) => switch (v) {
    MontyList(:final items) => pb.MontyNode(list: _indexes(items)),
    MontyTuple(:final items) => pb.MontyNode(tuple: _indexes(items)),
    MontySet(:final items) => pb.MontyNode(set: _indexes(items)),
    MontyFrozenSet(:final items) => pb.MontyNode(frozenSet: _indexes(items)),
    MontyDict(:final pairs) => pb.MontyNode(
      dict: pb.NodePairs(
        pairs: [
          for (final (k, x) in pairs) pb.NodePair(key: _id(k), value: _id(x)),
        ],
      ),
    ),
    _ => throw UnsupportedError(
      'a ${v.runtimeType} cannot be sent to the worker: the M2 value subset '
      'does not carry it',
    ),
  };

  pb.Indexes _indexes(List<MontyValue> items) =>
      pb.Indexes(items: [for (final i in items) _id(i)]);
}

/// The node for [v] when it is a leaf of the subset, else null.
pb.MontyNode? _scalarNode(MontyValue v) => switch (v) {
  MontyNone() => pb.MontyNode(none: pb.Unit()),
  MontyBool(:final value) => pb.MontyNode(boolean: value),
  MontyInt(:final value) => pb.MontyNode(int_5: Int64(value)),
  MontyBigInt(:final value) => _bigNode(value),
  MontyFloat(:final value) => pb.MontyNode(float: value),
  MontyString(:final value) => pb.MontyNode(str: value),
  MontyBytes(:final value) => pb.MontyNode(bytes: value),
  MontyPath(:final value) => pb.MontyNode(path: value),
  _ => null,
};

Iterable<MontyValue> _childrenOf(MontyValue v) => switch (v) {
  MontyList(:final items) ||
  MontyTuple(:final items) ||
  MontySet(:final items) ||
  MontyFrozenSet(:final items) => items,
  MontyDict(:final pairs) => [
    for (final (k, x) in pairs) ...[k, x],
  ],
  _ => const [],
};

final BigInt _int64Min = -(BigInt.one << 63);
final BigInt _int64Max = (BigInt.one << 63) - BigInt.one;
final BigInt _byteMask = BigInt.from(0xff);

/// The proto node for [value]: `int` when it fits in 64 bits, as upstream
/// emits, otherwise sign and big-endian magnitude.
pb.MontyNode _bigNode(BigInt value) {
  if (value >= _int64Min && value <= _int64Max) {
    return pb.MontyNode(int_5: Int64.parseInt(value.toString()));
  }
  final magnitude = value.abs();
  final bytes = Uint8List((magnitude.bitLength + 7) >> 3);
  var rest = magnitude;
  for (var i = bytes.length - 1; i >= 0; i--) {
    bytes[i] = (rest & _byteMask).toInt();
    rest >>= 8;
  }

  return pb.MontyNode(
    bigint: pb.BigInt(negative: value.isNegative, magnitude: bytes),
  );
}
