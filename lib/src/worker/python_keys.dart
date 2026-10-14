/// Python's key equality over arena nodes, for building dicts and sets.
///
/// Upstream builds each dict and set with Python's own constructors, so keys
/// that Python counts as equal collapse: `{1: 'a', True: 'b', 1.0: 'c'}` is
/// one entry, the first key with the last value. That equality is not
/// `MontyValue`'s `==` (which says `MontyInt(1) != MontyFloat(1.0)`), so it
/// is computed here, from the nodes themselves:
///
/// - numbers compare by value across `bool`, `int`, `float` and `complex`
///   (with a zero imaginary part);
/// - a NaN, an exception and a file handle are equal only to themselves:
///   to the same node;
/// - an object the host registered compares by its own `==` and
///   `hashCode`, as upstream inserts the original object with Python's;
/// - text compares by content, whether it came as `str`, a function name, a
///   `repr` or a `cycle` placeholder, since all of them decode to `str`;
/// - tuples and named tuples compare as tuples, frozensets as sets, both
///   only when every member is hashable;
/// - aware datetimes compare by instant, aware times by their UTC wall clock,
///   naive and aware never; a time zone compares by its offset alone;
/// - `list`, `dict`, `set` and the class proxies are unhashable.
///
/// Each node gets one interned integer: two nodes Python counts as equal get
/// the same one. A container's key is built from its members' integers, so a
/// shared tuple is keyed once, and building every key in an arena is linear
/// in its size.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';

/// Python keys for one arena's nodes.
final class PythonKeys {
  /// Keys for the arena's nodes; a class or instance node in the second
  /// argument decodes to that host object.
  PythonKeys(this._nodes, this._registered);

  final List<pb.MontyNode> _nodes;
  final Map<int, Object> _registered;

  /// Each node's interned key, or why it is unhashable.
  final Map<int, Object> _memo = {};
  final Map<String, int> _interned = {};
  final Map<Object, int> _objects = {};

  /// The interned key of node [index], whose index the arena has checked.
  ///
  /// Throws [FormatException] with Python's `TypeError` text when the value,
  /// or a member of it, is unhashable.
  int keyOf(int index) {
    // Each frame keeps a cursor into its members, so a wide tuple is walked
    // once, not rescanned after every member.
    final stack = [if (!_memo.containsKey(index)) index];
    final cursors = [0];
    for (var i = stack.lastOrNull; i != null; i = stack.lastOrNull) {
      final members = _members(_nodeAt(i));
      var at = cursors.removeLast();
      while (_memo.containsKey(members.elementAtOrNull(at))) {
        at++;
      }
      // Members are keyed in order, as Python hashes a tuple's elements, so
      // the first unhashable member is the one named.
      final next = members.elementAtOrNull(at);
      if (next != null && !_memo.containsKey(i)) {
        cursors.addAll([at, 0]);
        stack.add(next);
      } else {
        final done = i;
        _memo.putIfAbsent(done, () => _key(done, members));
        stack.removeLast();
      }
    }

    final key = _memo[index];
    if (key is int) return key;
    final type = key is _Unhashable ? key.type : '$key';
    throw FormatException("TypeError: unhashable type: '$type'");
  }

  /// The members a node's key is built from.
  List<int> _members(pb.MontyNode node) => switch (node.whichKind()) {
    pb.MontyNode_Kind.tuple => node.tuple.items,
    pb.MontyNode_Kind.namedTuple => node.namedTuple.values,
    pb.MontyNode_Kind.frozenSet => node.frozenSet.items,
    _ => const [],
  };

  /// Node [i]'s key, its members' keys being known; or an [_Unhashable].
  Object _key(int i, List<int> members) {
    final memberKeys = [for (final m in members) _memo[m]];
    final unhashable = memberKeys.whereType<_Unhashable>().firstOrNull;
    if (unhashable != null) return unhashable;
    if (_registered[i] case final object?) {
      return _objects.putIfAbsent(object, () => _intern('#${_objects.length}'));
    }
    final node = _nodeAt(i);
    final signature = (_signatures[node.whichKind()] ?? _unchecked)(
      node,
      memberKeys.whereType<int>().toList(),
    );

    return switch (signature) {
      final String text => _intern(text),
      // Equal only to itself.
      null => _intern('@$i'),
      final other => other,
    };
  }

  pb.MontyNode _nodeAt(int i) =>
      _nodes.elementAtOrNull(i) ?? (throw StateError('node $i is not checked'));

  int _intern(String signature) =>
      _interned.putIfAbsent(signature, () => _interned.length);
}

/// What makes two nodes of a kind equal keys: a signature string shared by
/// equal ones, null for a value equal only to itself, or an [_Unhashable].
final Map<pb.MontyNode_Kind, Object? Function(pb.MontyNode, List<int>)>
_signatures = {
  pb.MontyNode_Kind.none: (_, _) => 'N',
  pb.MontyNode_Kind.ellipsis: (_, _) => 'E',
  pb.MontyNode_Kind.notImplemented: (_, _) => 'I',
  pb.MontyNode_Kind.boolean: (n, _) => n.boolean ? 'n1' : 'n0',
  pb.MontyNode_Kind.int_5: (n, _) => 'n${intOfNode(n)}',
  pb.MontyNode_Kind.bigint: (n, _) => 'n${bigIntOfNode(n.bigint)}',
  pb.MontyNode_Kind.float: (n, _) => _number(floatOfNode(n)),
  pb.MontyNode_Kind.complex: (n, _) => _complex(n.complex),
  pb.MontyNode_Kind.str: (n, _) => 's${n.str}',
  pb.MontyNode_Kind.function: (n, _) => 's${n.function.name}',
  pb.MontyNode_Kind.repr: (n, _) => 's${n.repr}',
  pb.MontyNode_Kind.cycle: (n, _) => 's${n.cycle}',
  pb.MontyNode_Kind.bytes: (n, _) => 'b${String.fromCharCodes(n.bytes)}',
  pb.MontyNode_Kind.path: (n, _) => 'p${purePosixPath(n.path)}',
  pb.MontyNode_Kind.tuple: (_, keys) => 't${keys.join(',')}',
  pb.MontyNode_Kind.namedTuple: (_, keys) => 't${keys.join(',')}',
  pb.MontyNode_Kind.frozenSet: (_, keys) =>
      'f${(keys.toSet().toList()..sort()).join(',')}',
  pb.MontyNode_Kind.date: (n, _) => 'd${_ordinal(n.date)}',
  pb.MontyNode_Kind.datetime: (n, _) => _datetime(n.datetime),
  pb.MontyNode_Kind.time: (n, _) => _time(n.time),
  pb.MontyNode_Kind.timedelta: (n, _) =>
      'D${n.timedelta.days},${n.timedelta.seconds},'
      '${n.timedelta.microseconds}',
  pb.MontyNode_Kind.timezone: (n, _) => 'z${n.timezone.offsetSeconds}',
  // A builtin type or function: one object per name, and the builtin
  // function `type` is the type `type`.
  pb.MontyNode_Kind.type: (n, _) => n.type.origin == originBuiltin
      ? 'B${n.type.name}'
      : const _Unhashable('MontyClassTypeProxy'),
  pb.MontyNode_Kind.builtinFunction: (n, _) => 'B${n.builtinFunction}',
  pb.MontyNode_Kind.exception: (_, _) => null,
  pb.MontyNode_Kind.fileHandle: (_, _) => null,
  pb.MontyNode_Kind.classInstance: (_, _) =>
      const _Unhashable('MontyClassProxy'),
  pb.MontyNode_Kind.list: (_, _) => const _Unhashable('list'),
  pb.MontyNode_Kind.dict: (_, _) => const _Unhashable('dict'),
  pb.MontyNode_Kind.set: (_, _) => const _Unhashable('set'),
};

Never _unchecked(pb.MontyNode n, List<int> _) => throw StateError('$n');

/// A float's numeric signature, shared with an equal int; null for NaN,
/// which is equal only to itself.
String? _number(double v) {
  if (v.isNaN) return null;
  if (v.isInfinite) return v > 0 ? 'n+inf' : 'n-inf';
  if (v == v.truncateToDouble()) return 'n${BigInt.from(v)}';

  return 'x${doubleToBits(v).toHexString()}';
}

/// A complex number's signature: its real part's when the imaginary part is
/// zero, as `complex(1, 0) == 1`; null when a part is NaN.
String? _complex(pb.Complex c) {
  final real = _number(bitsToDouble(c.real));
  final imag = bitsToDouble(c.imag);
  if (imag == 0) return real;
  final imagKey = _number(imag);
  if (real == null || imagKey == null) return null;

  return 'c$real|$imagKey';
}

int _ordinal(pb.Date d) => ordinalDay(d.year, d.month, d.day);

/// Aware datetimes by instant; naive ones by their fields.
String _datetime(pb.DateTime d) {
  final day = ordinalDay(d.year, d.month, d.day);
  final seconds = day * 86400 + d.hour * 3600 + d.minute * 60 + d.second;
  if (!d.hasOffsetSeconds()) return 'Tn$seconds,${d.microsecond}';

  return 'Ta${seconds - d.offsetSeconds},${d.microsecond}';
}

/// Aware times by their UTC wall clock, as CPython's `time_richcompare`
/// subtracts the offset without wrapping; naive ones by their fields. Fold
/// and zone name take no part.
String _time(pb.Time t) {
  final seconds = t.hour * 3600 + t.minute * 60 + t.second;
  if (!t.hasOffsetSeconds()) return 'hn$seconds,${t.microsecond}';

  return 'ha${seconds - t.offsetSeconds},${t.microsecond}';
}

/// A value Python cannot hash, by its type's name.
final class _Unhashable {
  const _Unhashable(this.type);

  final String type;
}
