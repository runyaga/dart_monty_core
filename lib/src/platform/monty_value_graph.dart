part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Identity-aware equality, hashing and projections
// ---------------------------------------------------------------------------
//
// A MontyValue is a graph, not a tree: the worker shares one node between
// several parents, as Python shares objects. Walking it as a tree costs 2^d on
// `x = [x, x]` repeated d times, and recursing overflows the stack on deep
// nesting. Every operation here first recurses within a budget
// (ValueGraphBudget: 400 levels, 2^22 visits). Past either limit it restarts
// as a memoised walk on an explicit stack, which is linear in distinct nodes
// for nesting and for sharing with the same layout on both sides.
//
// On trees both paths give exactly the old results, and the hash values are
// the old ones too, except for sets, whose hash now mixes each element hash
// before the commutative sum. Work is not bounded against crafted values:
// colliding hashes, or equal DAGs that share on alternating levels, stay slow.

/// The operations the value classes delegate to.
abstract final class _MontyValueGraph {
  static int hash(Object v) {
    try {
      return _FastWalk().hash(v);
    } on _Abort {
      ValueGraphBudget.current?.recordFallback();

      return _MemoHasher().hash(v);
    }
  }

  static bool equals(Object a, Object b) {
    try {
      return _FastWalk().equals(a, b);
    } on _Abort {
      ValueGraphBudget.current?.recordFallback();

      return _MemoEquals(_MemoHasher()).equals(a, b);
    }
  }

  /// `toJson` of a container, which is never null.
  static Object nodeToJson(MontyValue v) =>
      _Projection().run(v, toJson: true) ?? (throw _notANode(v));

  /// `dartValue` of a container, which is never null.
  static Object nodeDartValue(MontyValue v) =>
      _Projection().run(v, toJson: false) ?? (throw _notANode(v));

  /// Projects every attribute through one dartValue projection, so values
  /// shared between attributes stay one object in the output.
  static Map<String, Object?> dartAttrs(Map<String, MontyValue> attrs) {
    final p = _Projection();

    return {
      for (final MapEntry(:key, :value) in attrs.entries)
        key: p.run(value, toJson: false),
    };
  }

  static MontyValue fromDart(Object? value) =>
      _fromDartScalar(value) ?? _FromDart().convert(value);
}

/// The node kinds the walk distinguishes.
const int _kFixed = 0; // a leaf with no variable-length payload
const int _kList = 1;
const int _kTuple = 2;
const int _kSet = 3;
const int _kFrozenSet = 4;
const int _kDict = 5;
const int _kNamedTuple = 6;
const int _kInstance = 7;
const int _kClassType = 8;
const int _kPayload = 9; // a leaf whose work grows with its payload

const int _hashMask = 0x7fffffff;

/// Up to this many elements, the fast path matches sets and dicts by
/// scanning, as the old code did: at most 36 comparisons, each charged, and
/// no hashing.
const int _scanLimit = 8;

int _kindOf(Object v) => (v as MontyValue)._graphKind;

bool _isLeafKind(int k) => k == _kFixed || k == _kPayload;

/// Whether equality and hashing treat kind [k] as a leaf: a class type
/// compares and hashes by its id alone, though its projection is a node.
bool _isEqLeafKind(int k) => _isLeafKind(k) || k == _kClassType;

/// The kind two values must share to be equal: a named tuple is a tuple,
/// and a frozenset a set, as Python compares them.
int _eqKind(int k) => switch (k) {
  _kNamedTuple => _kTuple,
  _kFrozenSet => _kSet,
  _ => k,
};

/// A tuple's or named tuple's items, else null.
List<MontyValue>? _tupleItems(Object v) => switch (v) {
  MontyTuple(:final items) => items,
  MontyNamedTuple(:final values) => values,
  _ => null,
};

/// A set's or frozenset's items, else null.
List<MontyValue>? _setItems(Object v) => switch (v) {
  MontySet(:final items) || MontyFrozenSet(:final items) => items,
  _ => null,
};

/// [xs] as Python's constructor builds a set or dict from them: each item
/// whose [key] equals an earlier one's is merged into it ([merge] of the
/// kept item and the later one) instead of kept. Up to [_scanLimit] items
/// are compared by scanning, more through buckets of their key's [hash].
List<T> _collapse<T>(
  List<T> xs, {
  required MontyValue Function(T) key,
  required T Function(T kept, T later) merge,
  required bool Function(Object, Object) same,
  required int Function(Object) hash,
}) {
  if (xs.length < 2) return xs;
  final out = <T>[];
  final buckets = <int, List<int>>{};
  final scan = xs.length <= _scanLimit;
  for (final x in xs) {
    final candidates = scan
        ? [for (var i = 0; i < out.length; i++) i]
        : (buckets[hash(key(x))] ??= []);
    final hit = candidates.where((i) => same(key(out[i]), key(x))).firstOrNull;
    if (hit != null) {
      out[hit] = merge(out[hit], x);
    } else {
      candidates.add(out.length);
      out.add(x);
    }
  }

  return out;
}

/// A set's members without repeats.
List<MontyValue> _distinct(
  List<MontyValue> xs,
  bool Function(Object, Object) same,
  int Function(Object) hash,
) => _collapse(
  xs,
  key: (x) => x,
  merge: (kept, _) => kept,
  same: same,
  hash: hash,
);

/// A dict's entries as Python keeps them: each key once, at its first
/// position, with its last value.
List<(MontyValue, MontyValue)> _entries(
  List<(MontyValue, MontyValue)> pairs,
  bool Function(Object, Object) same,
  int Function(Object) hash,
) => _collapse(
  pairs,
  key: (p) => p.$1,
  merge: (kept, later) => (kept.$1, later.$2),
  same: same,
  hash: hash,
);

/// Visits charged for a payload leaf, beyond the visit itself: one per 16
/// units of payload (8 for bytes, which compare element by element).
int _payloadCharge(Object v) => switch (v) {
  MontyString(:final value) || MontyPath(:final value) => value.length >> 4,
  MontyBytes(:final value) => value.length >> 3,
  MontyBigInt(:final value) => value.bitLength >> 9,
  _ => _textCharge(v),
};

int _textCharge(Object v) => switch (v) {
  MontyExceptionValue(:final excType, :final message) =>
    ((excType.length + (message?.length ?? 0)) >> 4) +
        _attributesCharge(v.attributes),
  MontyStdTypeProxy(:final kind, :final name) =>
    (kind.length + name.length) >> 4,
  MontyFileHandle(:final path, :final mode) => (path.length + mode.length) >> 4,
  _ => _zoneNameCharge(v),
};

/// An exception's attributes, charged as their keys and leaf values are.
int _attributesCharge(Map<String, MontyValue> attributes) {
  var units = 0;
  for (final MapEntry(:key, :value) in attributes.entries) {
    units += (key.length >> 4) + _payloadCharge(value);
  }

  return units;
}

int _zoneNameCharge(Object v) => switch (v) {
  MontyDateTime(:final timezoneName) ||
  MontyTime(:final timezoneName) => (timezoneName?.length ?? 0) >> 4,
  MontyTimeZone(:final name) => (name?.length ?? 0) >> 4,
  _ => 0,
};

/// The value graph walk exceeded its budget; always caught by the walk's
/// caller, which then takes the iterative path.
final class _Abort implements Exception {
  const _Abort();
}

const _abort = _Abort();

/// Carries a computed hash into `Object.hash`, which reads `hashCode`.
@immutable
final class _Hashed {
  const _Hashed(this.hashCode);

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) =>
      other is _Hashed && other.hashCode == hashCode;
}

StateError _cycle(String op) =>
    StateError('the value contains itself; $op is undefined on a cycle');

StateError _notANode(Object v) =>
    StateError('not a MontyValue container: ${v.runtimeType}');

// ---------------------------------------------------------------------------
// Hash formulas, shared by both paths so they cannot disagree
// ---------------------------------------------------------------------------

/// package:collection's `ListEquality.hash`, over precomputed element hashes.
int _stepSequenceHash(int hash, int element) {
  var h = (hash + element) & _hashMask;
  h = (h + (h << 10)) & _hashMask;

  return h ^ (h >> 6);
}

int _finishSequenceHash(int hash) {
  var h = (hash + (hash << 3)) & _hashMask;
  h ^= h >> 11;

  return (h + (h << 15)) & _hashMask;
}

/// Mixes one set element's hash before the commutative sum, so that sets
/// whose elements hash to small consecutive numbers rarely collide.
int _mixElementHash(int hash) {
  var h = hash & _hashMask;
  h = (h + (h << 10)) & _hashMask;
  h ^= h >> 6;
  h = (h + (h << 3)) & _hashMask;
  h ^= h >> 11;

  return (h + (h << 15)) & _hashMask;
}

/// Calls [f] on every child of the graph node [v].
void _forEachChild(Object v, void Function(Object) f) {
  switch (v) {
    case MontyList(:final items) ||
        MontyTuple(:final items) ||
        MontySet(:final items) ||
        MontyFrozenSet(:final items) ||
        MontyNamedTuple(values: final items):
      items.forEach(f);
    case MontyDict(:final pairs):
      for (final (k, x) in pairs) {
        f(k);
        f(x);
      }
    case MontyClassTypeProxy(:final attrs):
      attrs.values.forEach(f);
    case MontyClassProxy(:final attrs):
      // Its class compares by name and dataclass flag only (a class type
      // is an equality leaf), so only the attributes are children here.
      attrs.values.forEach(f);
  }
}

/// Computes a node's hash from its children's, through [child].
abstract class _Hasher {
  int child(Object v);

  /// Whether two children are equal, for collapsing repeated set members
  /// and dict keys.
  bool same(Object a, Object b);

  /// Counts [units] of work against the fast path's budget.
  void charge(int units);

  /// Counts [texts]: one unit each, then their length. The count comes first,
  /// so the texts are read only within the budget.
  void chargeTexts(Iterable<String> texts);

  int combine(Object v) => switch (v) {
    MontyList(:final items) || MontyTuple(:final items) => _seq(items),
    MontySet(:final items) || MontyFrozenSet(:final items) => _set(items),
    MontyDict(:final pairs) => _dict(pairs),
    _ => _combineStructured(v),
  };

  int _combineStructured(Object v) => switch (v) {
    // A tuple's hash, as Python's.
    MontyNamedTuple(:final values) => _seq(values),
    MontyClassProxy(:final classType, :final attrs) => Object.hash(
      _text(classType.name),
      classType.isDataclass,
      _attrs(attrs),
    ),
    _ => throw _notANode(v),
  };

  /// [s], after charging the work of hashing it.
  String _text(String s) {
    charge(s.length >> 4);

    return s;
  }

  int _seq(List<MontyValue> xs) {
    var h = 0;
    for (final x in xs) {
      h = _stepSequenceHash(h, child(x));
    }

    return _finishSequenceHash(h);
  }

  int _set(List<MontyValue> xs) {
    var h = 0;
    for (final x in _distinct(xs, same, child)) {
      h = (h + _mixElementHash(child(x))) & _hashMask;
    }

    return h;
  }

  /// An unbounded sum of `Object.hash(key, value)` over the entries Python
  /// keeps.
  int _dict(List<(MontyValue, MontyValue)> pairs) {
    var acc = 0;
    for (final (k, x) in _entries(pairs, same, child)) {
      acc += Object.hash(_Hashed(child(k)), _Hashed(child(x)));
    }

    return acc;
  }

  /// package:collection's `MapEquality.hash`, over each name's surviving
  /// value (an identity map can repeat a name; the last value is kept).
  int _attrs(Map<String, MontyValue> attrs) {
    chargeTexts(attrs.keys);
    var h = 0;
    for (final MapEntry(:key, :value) in _survivors(attrs).entries) {
      h = (h + key.hashCode * 3 + child(value) * 7) & _hashMask;
    }

    return _finishSequenceHash(h);
  }
}

// ---------------------------------------------------------------------------
// The fast path: recursive, within the budget
// ---------------------------------------------------------------------------

/// The recursive fast path. Throws [_abort] past the budget.
final class _FastWalk extends _Hasher {
  _FastWalk() : this._(ValueGraphBudget.current);

  _FastWalk._(ValueGraphBudget? budget)
    : _maxDepth = budget?.maxDepth ?? ValueGraphBudget.defaultMaxDepth,
      _maxVisits = budget?.maxVisits ?? ValueGraphBudget.defaultMaxVisits;

  final int _maxDepth;
  final int _maxVisits;
  int _visits = 0;
  int _depth = 0;

  int hash(Object v) {
    final k = _kindOf(v);
    if (_isEqLeafKind(k)) {
      _visit(k == _kPayload ? _payloadCharge(v) : 0);

      return v.hashCode;
    }
    _visit(0);
    _descend();
    final h = combine(v);
    _depth--;

    return h;
  }

  @override
  int child(Object v) => hash(v);

  @override
  bool same(Object a, Object b) => equals(a, b);

  @override
  void charge(int units) => _visit(units);

  @override
  void chargeTexts(Iterable<String> texts) {
    _visit(texts.length);
    _visit(_textLength(texts) >> 4);
  }

  bool equals(Object x, Object y) {
    if (identical(x, y)) {
      // Still a visit: a shared element compared with itself many times over
      // is work too.
      _visit(0);

      return true;
    }
    final kx = _kindOf(x);
    final ky = _kindOf(y);
    if (_isEqLeafKind(kx) || _isEqLeafKind(ky)) {
      // A leaf keeps its own rule (the numeric tower across classes; a
      // class type by id). Either side's payload may be read, so both are
      // charged.
      _visit(
        (kx == _kPayload ? _payloadCharge(x) : 0) +
            (ky == _kPayload ? _payloadCharge(y) : 0),
      );

      return x == y;
    }
    _visit(0);
    if (_eqKind(kx) != _eqKind(ky)) return false;
    _descend();
    final r = _equalNodes(x, y);
    _depth--;

    return r;
  }

  void _visit(int charge) {
    _visits += charge + 1;
    if (_visits > _maxVisits) throw _abort;
  }

  void _descend() {
    if (++_depth > _maxDepth) throw _abort;
  }

  bool _equalNodes(Object x, Object y) => switch ((x, y)) {
    (MontyList(items: final a), MontyList(items: final b)) => _equalSeq(a, b),
    (MontyDict(pairs: final a), MontyDict(pairs: final b)) => _equalDict(a, b),
    (final MontyClassProxy a, final MontyClassProxy b) => _equalInstances(
      this,
      a,
      b,
    ),
    _ => switch ((_tupleItems(x), _setItems(x), _tupleItems(y), _setItems(y))) {
      (final a?, _, final b?, _) => _equalSeq(a, b),
      (_, final a?, _, final b?) => _equalSet(a, b),
      _ => throw _notANode(x),
    },
  };

  bool _equalSeq(List<MontyValue> xs, List<MontyValue> ys) {
    if (xs.length != ys.length) return false;
    final other = ys.iterator;
    for (final x in xs) {
      other.moveNext();
      if (!equals(x, other.current)) return false;
    }

    return true;
  }

  /// The attribute maps compared by the value each name keeps: in step when
  /// the keys come in the same order, else as dict pairs (a map with its own
  /// key equality, an identity map, can repeat a name; the last value is
  /// kept, as a dict keeps it).
  bool _equalAttrs(Map<String, MontyValue> a, Map<String, MontyValue> b) {
    chargeTexts(a.keys);
    final repeats = _hasRepeatedKey(a, this) || _hasRepeatedKey(b, this);
    if (!repeats && a.length != b.length) return false;
    final inStep = a.length == b.length && _sameKeyOrder(a, b);
    if (inStep && _equalInStep(this, a.values, b.values)) return true;
    // Entries that do not line up can still be equal: keys in another
    // order, or a repeated key.
    if (inStep && !repeats) return false;

    return _equalDict(_attrPairs(a), _attrPairs(b));
  }

  /// Set equality over the distinct members (Python's set construction
  /// drops a repeat): by scanning up to [_scanLimit] elements, else through
  /// hash buckets.
  bool _equalSet(List<MontyValue> all, List<MontyValue> others) {
    final xs = _distinct(all, equals, hash);
    final ys = _distinct(others, equals, hash);
    if (xs.length != ys.length) return false;
    if (xs.length <= _scanLimit) return _scan(xs, ys, equals);
    final buckets = <int, List<MontyValue>>{};
    for (final y in ys) {
      (buckets[hash(y)] ??= []).add(y);
    }
    for (final x in xs) {
      if (!_take(buckets[hash(x)], (c) => equals(x, c))) return false;
    }

    return true;
  }

  /// Dict equality over the entries Python keeps (a repeated key collapses
  /// to its first, with the last value). Pairs are matched through buckets
  /// of their key's hash.
  bool _equalDict(
    List<(MontyValue, MontyValue)> all,
    List<(MontyValue, MontyValue)> others,
  ) {
    final xs = _entries(all, equals, hash);
    final ys = _entries(others, equals, hash);
    if (xs.length != ys.length) return false;
    if (xs.length <= _scanLimit) {
      return _scan(xs, ys, (p, q) => equals(p.$1, q.$1) && equals(p.$2, q.$2));
    }
    final buckets = <int, List<(MontyValue, MontyValue)>>{};
    for (final p in ys) {
      (buckets[hash(p.$1)] ??= []).add(p);
    }
    for (final (k, v) in xs) {
      final bucket = buckets[hash(k)];
      if (!_take(bucket, (c) => equals(k, c.$1) && equals(v, c.$2))) {
        return false;
      }
    }

    return true;
  }
}

/// Multiset matching by scan: each of [xs] takes an unused element
/// of [ys] that [eq] accepts.
bool _scan<T>(List<T> xs, List<T> ys, bool Function(T, T) eq) {
  final rest = [...ys];
  for (final x in xs) {
    if (!_take(rest, (c) => eq(x, c))) return false;
  }

  return true;
}

/// Removes the first element of [bucket] that [matches]; false if none
/// does.
bool _take<T>(List<T>? bucket, bool Function(T) matches) {
  for (final (j, c) in (bucket ?? <T>[]).indexed) {
    if (matches(c)) {
      bucket?.swapRemove(j);

      return true;
    }
  }

  return false;
}

/// Two class proxies, as upstream's `__eq__`: class name, dataclass flag
/// and attributes; neither id is compared.
bool _equalInstances(
  _FastWalk w,
  MontyClassProxy a,
  MontyClassProxy b,
) =>
    _equalText(w, a.classType.name, b.classType.name) &&
    a.classType.isDataclass == b.classType.isDataclass &&
    w._equalAttrs(a.attrs, b.attrs);

/// [a] == [b], after charging the comparison.
bool _equalText(_FastWalk w, String a, String b) {
  w.charge(a.length >> 4);

  return a == b;
}

/// The two value sequences compared pairwise on the fast path.
bool _equalInStep(
  _FastWalk w,
  Iterable<MontyValue> xs,
  Iterable<MontyValue> ys,
) {
  final other = ys.iterator;
  for (final x in xs) {
    other.moveNext();
    if (!w.equals(x, other.current)) return false;
  }

  return true;
}

extension<T> on List<T> {
  /// Removes the element at [j] in constant time, moving the last element
  /// into its place. Matching order does not matter: equality is an
  /// equivalence relation, so greedy matching succeeds exactly when the two
  /// multisets agree, whichever equal candidate each element takes.
  void swapRemove(int j) {
    final last = removeLast();
    if (j < length) this[j] = last;
  }
}

/// The total length of [texts].
int _textLength(Iterable<String> texts) =>
    texts.fold(0, (n, s) => n + s.length);

/// Whether [m] holds two equal keys, which only a map with its own key
/// equality (an identity map) can.
///
/// Keys are bucketed by hash and compared within a bucket, each comparison
/// charged to [w] (the fast path) so that colliding keys cannot hide work.
bool _hasRepeatedKey(Map<String, MontyValue> m, [_Hasher? w]) {
  final seen = <int, List<String>>{};
  for (final key in m.keys) {
    final bucket = seen[key.hashCode] ??= [];
    for (final other in bucket) {
      w?.charge((key.length >> 4) + 1);
      if (other == key) return true;
    }
    bucket.add(key);
  }

  return false;
}

/// Calls [f] on each child a projection of [v] builds. A string-keyed dict,
/// and an attribute map, project only the value that survives for each key,
/// as the string-keyed projection does.
void _forEachProjectedChild(Object v, void Function(Object) f) {
  switch (v) {
    case MontyClassTypeProxy(:final attrs):
      _survivors(attrs).values.forEach(f);
    case MontyClassProxy(:final classType, :final attrs):
      f(classType);
      _survivors(attrs).values.forEach(f);
    case final MontyDict d:
      final strings = _stringKeyed(d);
      if (strings == null) {
        _forEachChild(v, f);
      } else {
        strings.values.forEach(f);
      }
    default:
      _forEachChild(v, f);
  }
}

/// [d] as a string-keyed map, each key at its first position with its last
/// value, or `null` when any key is not a [MontyString].
Map<String, MontyValue>? _stringKeyed(MontyDict d) {
  final out = <String, MontyValue>{};
  for (final (k, v) in d.pairs) {
    if (k is! MontyString) return null;
    out[k.value] = v;
  }

  return out;
}

/// [attrs] with each key once, keeping its last value: a map with its own
/// key equality (an identity map) can repeat a key.
Map<String, MontyValue> _survivors(Map<String, MontyValue> attrs) => {
  for (final MapEntry(:key, :value) in attrs.entries) key: value,
};

/// Whether the two maps list equal keys in the same order.
bool _sameKeyOrder(Map<String, MontyValue> a, Map<String, MontyValue> b) {
  final other = b.keys.iterator;
  for (final key in a.keys) {
    if (!other.moveNext() || other.current != key) return false;
  }

  return true;
}

/// Attributes as dict pairs, so that keys compare as strings, whatever the
/// maps' own key equality.
List<(MontyValue, MontyValue)> _attrPairs(Map<String, MontyValue> m) => [
  for (final MapEntry(:key, :value) in m.entries) (MontyString(key), value),
];

/// Whether two class proxies' classes match as upstream compares them.
bool _sameClassHeader(MontyClassProxy a, MontyClassProxy b) =>
    a.classType.name == b.classType.name &&
    a.classType.isDataclass == b.classType.isDataclass;

// ---------------------------------------------------------------------------
// The fallback: memoised, on an explicit stack
// ---------------------------------------------------------------------------

/// Hashes with a memo keyed by identity. Every node and payload leaf is
/// hashed once per operation.
final class _MemoHasher extends _Hasher {
  final Map<Object, int> _memo = Map.identity();

  /// The fallback has no budget: it is linear in distinct nodes.
  @override
  void charge(int units) {
    assert(units >= 0, 'a negative charge: $units');
  }

  @override
  void chargeTexts(Iterable<String> texts) => charge(0);

  @override
  int child(Object v) {
    if (_isFixedForHash(_kindOf(v))) return v.hashCode;

    return _memo[v] ?? (throw StateError('child hashed before its parent'));
  }

  @override
  bool same(Object a, Object b) => _MemoEquals(this).equals(a, b);

  int hash(Object root) {
    final kind = _kindOf(root);
    if (_isFixedForHash(kind)) return root.hashCode;
    final hit = _memo[root];
    if (hit != null) return hit;
    if (kind == _kPayload) return _memo[root] = root.hashCode;
    _walk(root);

    return child(root);
  }

  void _walk(Object root) {
    final open = Set<Object>.identity();
    final stack = [root];
    for (var v = stack.lastOrNull; v != null; v = stack.lastOrNull) {
      if (_memo.containsKey(v)) {
        stack.removeLast();
        continue;
      }
      if (open.add(v) && _pushChildren(v, open, stack)) continue;
      stack.removeLast();
      open.remove(v);
      _memo[v] = combine(v);
    }
  }

  /// Pushes the children not yet hashed; false when there are none.
  bool _pushChildren(Object v, Set<Object> open, List<Object> stack) {
    final before = stack.length;
    _forEachChild(v, (c) {
      final k = _kindOf(c);
      if (_isFixedForHash(k) || _memo.containsKey(c)) return;
      if (k == _kPayload) {
        _memo[c] = c.hashCode;

        return;
      }
      if (open.contains(c)) throw _cycle('hashCode');
      stack.add(c);
    });

    return stack.length > before;
  }
}

/// Whether the memoised hash takes kind [k]'s hash without a memo entry: a
/// fixed-size leaf, or a class type (hashed by its id).
bool _isFixedForHash(int k) => k == _kFixed || k == _kClassType;

const Object _pending = Object();

/// One open comparison on the explicit stack.
///
/// [step] receives the result of the pair this frame last asked for (null on
/// the first call). It returns the frame's result, or null after setting
/// [px]/[py] to the next pair to compare.
abstract class _EqFrame {
  _EqFrame(this.x, this.y);

  final Object x;
  final Object y;
  Object px = _pending;
  Object py = _pending;

  // The result of the child comparison, fed back by the loop: positional is
  // the natural shape for a one-argument step function.
  // ignore: avoid_positional_boolean_parameters
  bool? step(bool? last);

  bool? ask(Object a, Object b) {
    px = a;
    py = b;

    return null;
  }
}

/// Compares two sequences pairwise; the first unequal pair decides.
final class _SeqFrame extends _EqFrame {
  _SeqFrame(super.x, super.y, List<Object> xs, List<Object> ys)
    : _xs = xs.iterator,
      _ys = ys.iterator;

  final Iterator<Object> _xs;
  final Iterator<Object> _ys;

  @override
  bool? step(bool? last) {
    if (last == false) return false;
    if (!_xs.moveNext()) return true;
    _ys.moveNext();

    return ask(_xs.current, _ys.current);
  }
}

/// Matches set elements through hash buckets; a failed candidate moves on to
/// the next one in the same bucket.
final class _SetFrame extends _EqFrame {
  _SetFrame(
    super.x,
    super.y,
    List<MontyValue> xs,
    this._hasher,
    List<MontyValue> ys,
  ) : _xs = xs.iterator,
      _all = xs.length <= _scanLimit ? [...ys] : null {
    if (_all != null) return;
    for (final e in ys) {
      (_buckets[_hasher.hash(e)] ??= []).add(e);
    }
  }

  final Iterator<MontyValue> _xs;
  final _MemoHasher _hasher;

  /// Every candidate, when the sets are small enough to scan as the fast
  /// path does: nothing is hashed then.
  final List<MontyValue>? _all;
  final Map<int, List<MontyValue>> _buckets = {};
  List<MontyValue> _bucket = const [];
  int _j = 0;

  @override
  bool? step(bool? last) {
    if (last == false) {
      _j++;

      return _offer();
    }
    if (last ?? false) _bucket.swapRemove(_j);
    if (!_xs.moveNext()) return true;
    _bucket = _all ?? _buckets[_hasher.hash(_xs.current)] ?? const [];
    _j = 0;

    return _offer();
  }

  bool? _offer() {
    final candidate = _bucket.elementAtOrNull(_j);

    return candidate == null ? false : ask(_xs.current, candidate);
  }
}

/// Matches dict pairs through buckets of their key's hash: a candidate
/// matches when its key and then its value compare equal.
final class _DictFrame extends _EqFrame {
  _DictFrame(
    super.x,
    super.y,
    List<(MontyValue, MontyValue)> xs,
    this._hasher,
    List<(MontyValue, MontyValue)> ys,
  ) : _xs = xs.iterator,
      _all = xs.length <= _scanLimit ? [...ys] : null {
    if (_all != null) return;
    for (final p in ys) {
      (_buckets[_hasher.hash(p.$1)] ??= []).add(p);
    }
  }

  final Iterator<(MontyValue, MontyValue)> _xs;
  final _MemoHasher _hasher;

  /// Every candidate, when the dicts are small enough to scan.
  final List<(MontyValue, MontyValue)>? _all;
  final Map<int, List<(MontyValue, MontyValue)>> _buckets = {};
  List<(MontyValue, MontyValue)> _bucket = const [];
  int _j = 0;
  bool _onValue = false;

  @override
  bool? step(bool? last) {
    final matched = last ?? false;
    if (matched && !_onValue) {
      // The key matched; now the value.
      _onValue = true;
      final candidate = _bucket.elementAtOrNull(_j);

      return candidate == null ? false : ask(_xs.current.$2, candidate.$2);
    }
    _onValue = false;
    if (last == false) {
      _j++;

      return _offer();
    }
    if (matched) _bucket.swapRemove(_j);

    return _nextPair();
  }

  bool? _nextPair() {
    if (!_xs.moveNext()) return true;
    _bucket = _all ?? _buckets[_hasher.hash(_xs.current.$1)] ?? const [];
    _j = 0;

    return _offer();
  }

  bool? _offer() {
    final candidate = _bucket.elementAtOrNull(_j);

    return candidate == null ? false : ask(_xs.current.$1, candidate.$1);
  }
}

/// Attribute maps whose keys line up, compared as the fast path compares
/// them: the values in step; when a value differs and the map holds a
/// repeated key, the entries as dict pairs.
final class _AttrsFrame extends _EqFrame {
  _AttrsFrame(super.x, super.y, this._a, this._b)
    : _xs = _a.values.iterator,
      _ys = _b.values.iterator;

  final Map<String, MontyValue> _a;
  final Map<String, MontyValue> _b;
  final Iterator<MontyValue> _xs;
  final Iterator<MontyValue> _ys;
  bool _asPairs = false;

  @override
  bool? step(bool? last) {
    if (_asPairs) return last;
    if (last == false) {
      if (!_hasRepeatedKey(_a) && !_hasRepeatedKey(_b)) return false;
      _asPairs = true;

      return ask(MontyDict(_attrPairs(_a)), MontyDict(_attrPairs(_b)));
    }
    if (!_xs.moveNext()) return true;
    _ys.moveNext();

    return ask(_xs.current, _ys.current);
  }
}

/// Equality on an explicit stack, memoising every pair it settles.
final class _MemoEquals {
  _MemoEquals(this._hasher);

  final _MemoHasher _hasher;

  /// x -> (y -> true, false or [_pending]).
  final Map<Object, Map<Object, Object>> _pairs = Map.identity();

  bool equals(Object a, Object b) {
    final first = _open(a, b);
    if (first is! _EqFrame) return first == true;
    final stack = [first];
    bool? carry;
    for (var f = stack.lastOrNull; f != null; f = stack.lastOrNull) {
      final r = f.step(carry);
      carry = null;
      if (r == null) {
        final next = _open(f.px, f.py);
        if (next is _EqFrame) {
          stack.add(next);
        } else {
          carry = next == true;
        }
        continue;
      }
      stack.removeLast();
      _pairs[f.x]?[f.y] = r;
      carry = r;
    }

    return carry ?? (throw StateError('the comparison produced no result'));
  }

  /// The result for (x, y) when it is known without descending (a bool),
  /// else a new frame for it, marked open.
  Object _open(Object x, Object y) {
    if (identical(x, y)) return true;
    final kx = _kindOf(x);
    final ky = _kindOf(y);
    if (_isEqLeafKind(kx) || _isEqLeafKind(ky)) {
      return _leafEquals(x, y, kx, ky);
    }
    if (_eqKind(kx) != _eqKind(ky)) return false;
    final row = _pairs[x] ??= Map.identity();
    final known = row[y];
    if (known is bool) return known;
    if (known != null) throw _cycle('==');
    final frame = _frameFor(x, y);
    row[y] = frame == null ? false : _pending;

    return frame ?? false;
  }

  /// Leaf equality, memoised unless both leaves are fixed-size.
  bool _leafEquals(Object x, Object y, int kx, int ky) {
    if (_isFixedForHash(kx) && _isFixedForHash(ky)) return x == y;
    final row = _pairs[x] ??= Map.identity();
    final known = row[y];
    if (known is bool) return known;
    final r = x == y;
    row[y] = r;

    return r;
  }

  /// A frame comparing two nodes of one kind, or null when something that
  /// needs no descent already differs.
  _EqFrame? _frameFor(Object x, Object y) => switch ((x, y)) {
    (MontyList(items: final a), MontyList(items: final b)) =>
      a.length == b.length ? _SeqFrame(x, y, a, b) : null,
    (MontyDict(pairs: final a), MontyDict(pairs: final b)) => _dictFrame(
      x,
      y,
      a,
      b,
    ),
    (final MontyClassProxy a, final MontyClassProxy b) =>
      _sameClassHeader(a, b) ? _attrsFrame(a, b, a.attrs, b.attrs) : null,
    _ => switch ((_tupleItems(x), _setItems(x), _tupleItems(y), _setItems(y))) {
      (final a?, _, final b?, _) =>
        a.length == b.length ? _SeqFrame(x, y, a, b) : null,
      (_, final a?, _, final b?) => _setFrame(x, y, a, b),
      _ => throw _notANode(x),
    },
  };

  /// Repeats are collapsed first, each comparison on its own walk, so that
  /// the frame compares what Python's constructor would have kept.
  bool _same(Object a, Object b) => _MemoEquals(_hasher).equals(a, b);

  _EqFrame? _setFrame(
    Object x,
    Object y,
    List<MontyValue> all,
    List<MontyValue> others,
  ) {
    final a = _distinct(all, _same, _hasher.hash);
    final b = _distinct(others, _same, _hasher.hash);

    return a.length == b.length ? _SetFrame(x, y, a, _hasher, b) : null;
  }

  _EqFrame? _dictFrame(
    Object x,
    Object y,
    List<(MontyValue, MontyValue)> all,
    List<(MontyValue, MontyValue)> others,
  ) {
    final a = _entries(all, _same, _hasher.hash);
    final b = _entries(others, _same, _hasher.hash);

    return a.length == b.length ? _DictFrame(x, y, a, _hasher, b) : null;
  }

  /// Compares the attribute values by name, as the fast path does.
  _EqFrame? _attrsFrame(
    Object x,
    Object y,
    Map<String, MontyValue> a,
    Map<String, MontyValue> b,
  ) {
    final repeats = _hasRepeatedKey(a) || _hasRepeatedKey(b);
    if (!repeats && a.length != b.length) return null;
    if (a.length == b.length && _sameKeyOrder(a, b)) {
      return _AttrsFrame(x, y, a, b);
    }

    return _SeqFrame(
      x,
      y,
      [MontyDict(_attrPairs(a))],
      [MontyDict(_attrPairs(b))],
    );
  }
}

// ---------------------------------------------------------------------------
// Projections: toJson and dartValue
// ---------------------------------------------------------------------------

/// Builds `toJson` or `dartValue` output.
///
/// Each node is built once per projection, so a node shared in the value is
/// one shared object in the output. A named tuple and a
/// class instance project to their `toJson` map in both projections.
final class _Projection {
  final Map<Object, Object?> _json = Map.identity();
  final Map<Object, Object?> _dart = Map.identity();
  final int _maxDepth =
      ValueGraphBudget.current?.maxDepth ?? ValueGraphBudget.defaultMaxDepth;
  int _depth = 0;

  /// Whether children come from [_get] (the fallback) or [_recurse].
  bool _iterating = false;

  /// Projects [root], falling back to the explicit stack when deep.
  Object? run(Object root, {required bool toJson}) {
    // An earlier run that gave up left its state behind.
    _depth = 0;
    _iterating = false;
    try {
      return _recurse(root, toJson: toJson);
    } on _Abort {
      ValueGraphBudget.current?.recordFallback();

      _iterating = true;

      return _iterate(root, toJson: toJson);
    }
  }

  /// Whether [kind] in the dartValue projection is built as its toJson map.
  static bool _jsonInBoth(int kind) =>
      kind == _kNamedTuple || kind == _kInstance || kind == _kClassType;

  Map<Object, Object?> _memoFor({required bool json}) => json ? _json : _dart;

  Object? _leaf(Object v, int kind, {required bool toJson}) {
    final memo = _memoFor(json: toJson);
    if (kind == _kFixed || v is MontyString) {
      final m = v as MontyValue;
      final out = toJson ? m._toJson() : m.dartValue;
      // A shared leaf that projects to an object (a tagged float, a date)
      // is one object in the output too; a primitive has no identity.
      if (out == null || out is num || out is bool || out is String) {
        return out;
      }

      return memo.putIfAbsent(v, () => out);
    }
    if (memo.containsKey(v)) return memo[v];
    final m = v as MontyValue;

    return memo[v] = toJson ? m._toJson() : m.dartValue;
  }

  Object? _recurse(Object v, {required bool toJson}) {
    final kind = _kindOf(v);
    if (_isLeafKind(kind)) return _leaf(v, kind, toJson: toJson);
    final json = toJson || _jsonInBoth(kind);
    final memo = _memoFor(json: json);
    final hit = memo[v];
    if (hit != null) return hit;
    if (++_depth > _maxDepth) throw _abort;
    final out = _build(v, toJson: json);
    _depth--;

    return memo[v] = out;
  }

  /// A child's output in the projection [toJson] names.
  Object? _child(Object c, {required bool toJson}) =>
      _iterating ? _get(c, toJson: toJson) : _recurse(c, toJson: toJson);

  /// The output already built for [c] in the projection its parent uses.
  Object? _get(Object c, {required bool toJson}) {
    final kind = _kindOf(c);
    if (_isLeafKind(kind)) return _leaf(c, kind, toJson: toJson);

    return _memoFor(json: toJson || _jsonInBoth(kind))[c];
  }

  Object? _iterate(Object root, {required bool toJson}) {
    final stack = [(root, toJson)];
    for (var top = stack.lastOrNull; top != null; top = stack.lastOrNull) {
      final (v, requested) = top;
      final kind = _kindOf(v);
      final json = requested || _jsonInBoth(kind);
      final memo = _memoFor(json: json);
      final state = memo[v];
      if (_isLeafKind(kind) || (state != null && state != _pending)) {
        stack.removeLast();
        continue;
      }
      if (state == null) {
        memo[v] = _pending;
        if (_pushChildren(v, stack, json: json)) continue;
      }
      stack.removeLast();
      memo[v] = _build(v, toJson: json);
    }

    return _get(root, toJson: toJson);
  }

  /// Pushes the container children not yet built; false when there are none.
  bool _pushChildren(
    Object v,
    List<(Object, bool)> stack, {
    required bool json,
  }) {
    final before = stack.length;
    void push(Object c) {
      final kind = _kindOf(c);
      if (_isLeafKind(kind)) return;
      final state = _memoFor(json: json || _jsonInBoth(kind))[c];
      if (state == _pending) throw _cycle(json ? 'toJson' : 'dartValue');
      if (state == null) stack.add((c, json));
    }

    _forEachProjectedChild(v, push);

    return stack.length > before;
  }

  /// The output for node [v], built from its children's outputs.
  Object _build(Object v, {required bool toJson}) => switch (v) {
    MontyList(:final items) => [
      for (final c in items) _child(c, toJson: toJson),
    ],
    MontyTuple(:final items) => _tagged('tuple', items, toJson: toJson),
    MontySet(:final items) => _tagged('set', items, toJson: toJson),
    MontyFrozenSet(:final items) => _tagged('frozenset', items, toJson: toJson),
    final MontyDict d => _dict(d, toJson: toJson),
    _ => _buildStructured(v),
  };

  Object _tagged(
    String tag,
    List<MontyValue> items, {
    required bool toJson,
  }) {
    final out = [for (final c in items) _child(c, toJson: toJson)];

    return toJson ? <String, Object?>{'__type': tag, 'value': out} : out;
  }

  /// The string-keyed form when every key is a string, as the old code built
  /// it: the first position of each key, with its last
  /// value. Otherwise the entries form.
  Object _dict(MontyDict d, {required bool toJson}) {
    Object? get(Object c) => _child(c, toJson: toJson);
    final strings = _stringKeyed(d);
    if (strings != null) {
      final out = <String, Object?>{
        for (final MapEntry(:key, :value) in strings.entries) key: get(value),
      };

      return toJson ? <String, Object?>{'__type': 'dict', 'value': out} : out;
    }
    final entries = [
      for (final (k, x) in d.pairs) [get(k), get(x)],
    ];

    return toJson
        ? <String, Object?>{'__type': 'dict', 'entries': entries}
        : entries;
  }

  /// Named tuples, class types and class instances: always toJson maps.
  Object _buildStructured(Object v) => switch (v) {
    MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
      <String, Object?>{
        '__type': 'namedtuple',
        'type_name': typeName,
        'field_names': fieldNames,
        'values': [for (final c in values) _child(c, toJson: true)],
      },
    // Map<String, Object>, as the untyped literal it replaces inferred.
    MontyClassTypeProxy(
      :final name,
      :final id,
      :final hostDefined,
      :final isDataclass,
      :final attrs,
    ) =>
      <String, Object>{
        '__type': 'class_type',
        'name': name,
        'id': id,
        'host_defined': hostDefined,
        'is_dataclass': isDataclass,
        'attrs': _attrsJson(attrs),
      },
    MontyClassProxy(:final classType, :final instanceId, :final attrs) =>
      <String, Object?>{
        '__type': 'class_instance',
        'class_type': _child(classType, toJson: true),
        'instance_id': instanceId,
        'attrs': _attrsJson(attrs),
      },
    _ => throw _notANode(v),
  };

  /// An attribute map in the dict envelope, string-keyed.
  Map<String, Object?> _attrsJson(Map<String, MontyValue> attrs) => {
    '__type': 'dict',
    'value': <String, Object?>{
      for (final MapEntry(:key, :value) in _survivors(attrs).entries)
        key: _child(value, toJson: true),
    },
  };
}

// ---------------------------------------------------------------------------
// fromDart
// ---------------------------------------------------------------------------

/// The value for a Dart scalar, or null for a List or Map.
MontyValue? _fromDartScalar(Object? value) => switch (value) {
  final MontyValue mv => mv,
  null => const MontyNone(),
  final bool b => MontyBool(b),
  final num n => _fromDartNumber(n),
  final String s => MontyString(s),
  final DateTime dt => _fromDartDateTime(dt),
  List<Object?>() || Map<dynamic, dynamic>() => null,
  _ => throw ArgumentError('Cannot convert ${value.runtimeType} to MontyValue'),
};

/// `-0.0` and the infinities are tested before `int`: on dart2js an integral
/// double passes `is int`, and all three are integral there.
MontyValue _fromDartNumber(num n) {
  if (n is double && (n.isInfinite || (n == 0 && n.isNegative))) {
    return MontyFloat(n);
  }

  return n is int ? MontyInt(n) : MontyFloat(n.toDouble());
}

/// An aware datetime at [d]'s instant: its own fields with its UTC offset,
/// zero for a UTC [DateTime].
MontyDateTime _fromDartDateTime(DateTime d) => MontyDateTime(
  year: d.year,
  month: d.month,
  day: d.day,
  hour: d.hour,
  minute: d.minute,
  second: d.second,
  // Dart splits the fraction into milliseconds and microseconds; Python's
  // microsecond field holds both.
  microsecond: d.millisecond * 1000 + d.microsecond,
  offsetSeconds: d.isUtc ? 0 : d.timeZoneOffset.inSeconds,
);

/// Converts Lists and Maps without recursion. One reached twice becomes one
/// value; one that contains itself is an [ArgumentError].
/// A memo key for one kind of zero. Distinct fields keep the three
/// constants distinct: `const Object()` would canonicalise them into one.
final class _ZeroKey {
  const _ZeroKey(this.kind);

  final String kind;
}

const _intZero = _ZeroKey('int');
const _floatZero = _ZeroKey('float');
const _negativeZero = _ZeroKey('-0.0');

final class _FromDart {
  final Map<Object, MontyValue> _done = Map.identity();
  final Set<Object> _open = Set.identity();
  final List<Object> _stack = [];

  MontyValue convert(Object? root) {
    if (root == null) return const MontyNone();
    _stack.add(root);
    for (var v = _stack.lastOrNull; v != null; v = _stack.lastOrNull) {
      if (_done.containsKey(v)) {
        _stack.removeLast();
        continue;
      }
      if (_open.add(v) && _pushChildren(v)) continue;
      _stack.removeLast();
      _open.remove(v);
      _done[v] = _build(v);
    }

    return _value(root);
  }

  /// A scalar reached twice also becomes one value.
  MontyValue _value(Object? c) {
    final key = _memoKey(c);
    final done = _done[key];
    if (done != null) return done;
    final scalar =
        _fromDartScalar(c) ??
        (throw StateError('converted a container before its children'));
    if (key != null) _done[key] = scalar;

    return scalar;
  }

  /// The identity-memo key for [c]. A zero is keyed by what it converts to:
  /// dart2js holds 0 and -0.0 as one identity key.
  static Object? _memoKey(Object? c) {
    if (c is! num || c != 0) return c;
    if (c is double && c.isNegative) return _negativeZero;
    if (c is int) return _intZero;

    return _floatZero;
  }

  bool _pushChildren(Object v) {
    final before = _stack.length;
    switch (v) {
      case final List<Object?> l:
        l.forEach(_push);
      case final Map<dynamic, dynamic> m:
        for (final MapEntry(:key, :value) in m.entries) {
          _push(key);
          _push(value);
        }
    }

    return _stack.length > before;
  }

  void _push(Object? c) {
    if (c == null || (c is! List<Object?> && c is! Map<dynamic, dynamic>)) {
      return;
    }
    if (_done.containsKey(c)) return;
    if (_open.contains(c)) {
      throw ArgumentError('Cannot convert a List or Map that contains itself');
    }
    _stack.add(c);
  }

  MontyValue _build(Object v) => v is List<Object?>
      ? MontyList([for (final c in v) _value(c)])
      : MontyDict([
          for (final MapEntry(:key, :value)
              in (v as Map<dynamic, dynamic>).entries)
            (_value(key), _value(value)),
        ]);
}
