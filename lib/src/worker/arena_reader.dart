/// Values from the worker: a monty-proto `Arena` to [MontyValue].
///
/// An arena is a flat list of nodes in post-order: a container holds the
/// indexes of its children, every child index is lower than its holder's, and
/// a value referenced twice is one node referenced twice. Decoding builds
/// each node once, so a sub-list shared by two parents decodes to one Dart
/// object, as it is one object in Python. `ArenaWriter` keeps the same
/// identity in the other direction.
///
/// The decoder walks an explicit stack, so the depth of a value is bounded by
/// memory, not by the Dart call stack, on every compiler.
///
/// Only the kinds the M2 cases need are carried: `None`, `bool`, `int` of any
/// size, `float`, `complex`, `str`, `bytes`, `list`, `tuple`, `dict`, `set`,
/// `frozenset` and `pathlib.Path`. Any other kind throws [UnsupportedError]
/// naming it.
///
/// Known gap: an `int` node whose magnitude is at least 2^62 decodes wrongly,
/// because package:protobuf's sint64 (zigzag) decoding uses an arithmetic
/// shift. Values that size need a workaround below the generated bindings;
/// until then they are not part of the subset.
///
/// A decoded value can be a graph rather than a tree, and [MontyValue]'s
/// `==`, `hashCode`, `toJson` and `dartValue` walk a graph as if it were a
/// tree, so their cost doubles with each level of sharing. Nothing on this
/// path calls them, and nothing here is exported; values from this decoder
/// reach users only once those operations understand sharing.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';

/// Reads values out of one arena.
///
/// Each node is decoded at most once, however many roots or parents refer to
/// it: two roots naming the same node give the identical Dart object.
final class ArenaReader {
  /// Creates a reader over [arena]'s nodes.
  ArenaReader(pb.Arena arena) : _nodes = arena.nodes;

  final List<pb.MontyNode> _nodes;
  final Map<int, MontyValue> _decoded = {};

  /// The value rooted at node [index].
  ///
  /// Throws [FormatException] if [index] or any child index is out of range,
  /// or a child index is not lower than its holder's, and [UnsupportedError]
  /// for a node kind outside the subset this decoder carries.
  MontyValue operator [](int index) {
    _checkIndex(index, _nodes.length, 'root');
    final stack = [index];
    for (var i = stack.lastOrNull; i != null; i = stack.lastOrNull) {
      if (_decoded.containsKey(i)) {
        stack.removeLast();
        continue;
      }
      final node = _nodeAt(i);
      final pending = [
        for (final c in _childrenOf(node, i))
          if (!_decoded.containsKey(c)) c,
      ];
      if (pending.isEmpty) {
        _decoded[i] = _build(node);
        stack.removeLast();
      } else {
        stack.addAll(pending);
      }
    }

    return _at(index);
  }

  pb.MontyNode _nodeAt(int i) =>
      _nodes.elementAtOrNull(i) ??
      (throw StateError('arena node $i is outside the arena'));

  MontyValue _at(int i) =>
      _decoded[i] ??
      (throw StateError('arena node $i was read before it was decoded'));

  /// The child indexes of [node], each checked to be below [holder].
  List<int> _childrenOf(pb.MontyNode node, int holder) {
    final children = switch (node.whichKind()) {
      pb.MontyNode_Kind.list => node.list.items,
      pb.MontyNode_Kind.tuple => node.tuple.items,
      pb.MontyNode_Kind.set => node.set.items,
      pb.MontyNode_Kind.frozenSet => node.frozenSet.items,
      pb.MontyNode_Kind.dict => [
        for (final p in node.dict.pairs) ...[p.key, p.value],
      ],
      _ => const <int>[],
    };
    for (final c in children) {
      _checkIndex(c, holder, 'child of node $holder');
    }

    return children;
  }

  /// Builds [node], whose children are all decoded.
  MontyValue _build(pb.MontyNode node) => _scalar(node) ?? _container(node);

  MontyValue _container(pb.MontyNode node) => switch (node.whichKind()) {
    pb.MontyNode_Kind.list => MontyList(_items(node.list.items)),
    pb.MontyNode_Kind.tuple => MontyTuple(_items(node.tuple.items)),
    pb.MontyNode_Kind.set => MontySet(_items(node.set.items)),
    pb.MontyNode_Kind.frozenSet => MontyFrozenSet(
      _items(node.frozenSet.items),
    ),
    pb.MontyNode_Kind.dict => MontyDict(
      List.unmodifiable([
        for (final p in node.dict.pairs) (_at(p.key), _at(p.value)),
      ]),
    ),
    final kind => throw UnsupportedError(
      'the worker sent a "${kind.name}" value, which the M2 value subset '
      'does not carry',
    ),
  };

  List<MontyValue> _items(List<int> indexes) =>
      List.unmodifiable([for (final c in indexes) _at(c)]);
}

/// The largest magnitude every backend holds exactly in a Dart `int`.
///
/// Beyond it an integer decodes as [MontyBigInt], as on the JSON path, so a
/// value's Dart type does not depend on the compiler.
final BigInt _exactIntLimit = BigInt.one << 53;

/// [node] as a value when it is a leaf of the subset, else null.
MontyValue? _scalar(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.none => const MontyNone(),
  pb.MontyNode_Kind.boolean => MontyBool(node.boolean),
  pb.MontyNode_Kind.int_5 => _intValue(_bigFromInt64(node.int_5)),
  pb.MontyNode_Kind.bigint => _intValue(_bigFromProto(node.bigint)),
  pb.MontyNode_Kind.float => MontyFloat(node.float),
  pb.MontyNode_Kind.complex => MontyComplex(
    node.complex.real,
    node.complex.imag,
  ),
  pb.MontyNode_Kind.str => MontyString(node.str),
  pb.MontyNode_Kind.bytes => MontyBytes(
    Uint8List.fromList(node.bytes).asUnmodifiableView(),
  ),
  pb.MontyNode_Kind.path => MontyPath(node.path),
  _ => null,
};

BigInt _bigFromInt64(Int64 v) => BigInt.parse(v.toString());

BigInt _bigFromProto(pb.BigInt b) {
  var v = BigInt.zero;
  for (final byte in b.magnitude) {
    v = (v << 8) | BigInt.from(byte);
  }

  return b.negative ? -v : v;
}

/// [MontyInt] within ±2^53, [MontyBigInt] beyond: the rule the JSON path
/// already follows.
MontyValue _intValue(BigInt v) =>
    v.abs() <= _exactIntLimit ? MontyInt(v.toInt()) : MontyBigInt(v);

void _checkIndex(int index, int bound, String what) {
  if (index < 0 || index >= bound) {
    throw FormatException(
      'arena $what index $index is outside 0..${bound - 1}; the worker '
      'sent a malformed arena',
    );
  }
}
