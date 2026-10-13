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
const int _kDataclass = 8;
const int _kClassType = 9;
const int _kPayload = 10; // a leaf whose work grows with its payload

const int _hashMask = 0x7fffffff;

/// Up to this many elements, the fast path matches sets and dicts by
/// scanning, as the old code did: at most 36 comparisons, each charged, and
/// no hashing.
const int _scanLimit = 8;

int _kindOf(Object v) => v is MontyValue ? v._graphKind : _kClassType;

bool _isLeafKind(int k) => k == _kFixed || k == _kPayload;

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
    (excType.length + (message?.length ?? 0)) >> 4,
  MontyOpaque(:final text) => text.length >> 4,
  MontyFileHandle(:final path, :final mode) => (path.length + mode.length) >> 4,
  _ => _zoneNameCharge(v),
};

int _zoneNameCharge(Object v) => switch (v) {
  MontyDateTime(:final timezoneName) ||
  MontyTime(:final timezoneName) => (timezoneName?.length ?? 0) >> 4,
  MontyTimeZone(:final name) => (name?.length ?? 0) >> 4,
  _ => 0,
};

final class _Abort implements Exception {
  const _Abort();

  @override
  String toString() => 'the value graph walk exceeded its budget';
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

int _stringListHash(List<String> xs) {
  var h = 0;
  for (final s in xs) {
    h = _stepSequenceHash(h, s.hashCode);
  }

  return _finishSequenceHash(h);
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
    case MontyClassType(:final attrs) || MontyDataclass(:final attrs):
      attrs.values.forEach(f);
    case MontyClassInstance(:final classType, :final attrs):
      f(classType);
      attrs.values.forEach(f);
  }
}

/// Computes a node's hash from its children's, through [child].
abstract class _Hasher {
  int child(Object v);

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
    MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
      Object.hash(_text(typeName), _names(fieldNames), _seq(values)),
    MontyClassType(
      :final name,
      :final id,
      :final hostDefined,
      :final isDataclass,
      :final attrs,
    ) =>
      Object.hash(
        _text(name),
        _text(id),
        hostDefined,
        isDataclass,
        _attrs(attrs),
      ),
    MontyClassInstance(:final classType, :final instanceId, :final attrs) =>
      Object.hash(_Hashed(child(classType)), _text(instanceId), _attrs(attrs)),
    MontyDataclass(
      :final name,
      :final typeId,
      :final fieldNames,
      :final attrs,
      :final frozen,
    ) =>
      Object.hash(
        _text(name),
        typeId,
        _names(fieldNames),
        _attrs(attrs),
        frozen,
      ),
    _ => throw _notANode(v),
  };

  /// [s], after charging the work of hashing it.
  String _text(String s) {
    charge(s.length >> 4);

    return s;
  }

  int _names(List<String> names) {
    chargeTexts(names);

    return _stringListHash(names);
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
    for (final x in xs) {
      h = (h + _mixElementHash(child(x))) & _hashMask;
    }

    return h;
  }

  /// The old dict hash: an unbounded sum of `Object.hash(key, value)`.
  int _dict(List<(MontyValue, MontyValue)> pairs) {
    var acc = 0;
    for (final (k, x) in pairs) {
      acc += Object.hash(_Hashed(child(k)), _Hashed(child(x)));
    }

    return acc;
  }

  /// package:collection's `MapEquality.hash`.
  int _attrs(Map<String, MontyValue> attrs) {
    chargeTexts(attrs.keys);
    var h = 0;
    for (final MapEntry(:key, :value) in attrs.entries) {
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
    if (_isLeafKind(k)) {
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
    if (_isLeafKind(kx) && _isLeafKind(ky)) {
      // Two leaf kinds keep their own rule (MontyInt equals MontyBigInt).
      // Either side's payload may be read, so both are charged.
      _visit(
        (kx == _kPayload ? _payloadCharge(x) : 0) +
            (ky == _kPayload ? _payloadCharge(y) : 0),
      );

      return x == y;
    }
    _visit(0);
    if (kx != ky) return false;
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
    (MontyList(items: final a), MontyList(items: final b)) ||
    (MontyTuple(items: final a), MontyTuple(items: final b)) => _equalSeq(a, b),
    (MontySet(items: final a), MontySet(items: final b)) ||
    (
      MontyFrozenSet(items: final a),
      MontyFrozenSet(items: final b),
    ) => _equalSet(a, b),
    (MontyDict(pairs: final a), MontyDict(pairs: final b)) => _equalDict(a, b),
    _ => _equalStructured(this, x, y),
  };

  bool _equalStrings(List<String> a, List<String> b) {
    chargeTexts(a);

    return _stringsEqual(a, b);
  }

  bool _equalSeq(List<MontyValue> xs, List<MontyValue> ys) {
    if (xs.length != ys.length) return false;
    final other = ys.iterator;
    for (final x in xs) {
      other.moveNext();
      if (!equals(x, other.current)) return false;
    }

    return true;
  }

  /// The attribute maps' entries as a multiset, as MapEquality compared
  /// them: in step when the keys come in the same order, else as dict pairs.
  bool _equalAttrs(Map<String, MontyValue> a, Map<String, MontyValue> b) {
    if (a.length != b.length) return false;
    chargeTexts(a.keys);
    final inStep = _sameKeyOrder(a, b);
    if (inStep && _equalInStep(this, a.values, b.values)) return true;
    // Entries that do not line up can still be equal as a multiset: keys in
    // another order, or a map (an identity map) holding two equal keys.
    if (inStep && !_hasRepeatedKey(a, this)) return false;

    return _equalDict(_attrPairs(a), _attrPairs(b));
  }

  /// Multiset equality, as the old list scan had: by scanning up to
  /// [_scanLimit] elements, else through hash buckets.
  bool _equalSet(List<MontyValue> xs, List<MontyValue> ys) {
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

  /// Pair-multiset equality, as the old `remaining.remove(pair)` scan had:
  /// a dict built with a duplicate key compares as before. Pairs are matched
  /// through buckets of their key's hash.
  bool _equalDict(
    List<(MontyValue, MontyValue)> xs,
    List<(MontyValue, MontyValue)> ys,
  ) {
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

/// The structured kinds on the fast path; top-level to keep [_FastWalk]
/// small.
bool _equalStructured(_FastWalk w, Object x, Object y) => switch ((x, y)) {
  (final MontyNamedTuple a, final MontyNamedTuple b) => _equalNamedTuples(
    w,
    a,
    b,
  ),
  (final MontyClassType a, final MontyClassType b) => _equalClassTypes(w, a, b),
  (final MontyClassInstance a, final MontyClassInstance b) => _equalInstances(
    w,
    a,
    b,
  ),
  (final MontyDataclass a, final MontyDataclass b) => _equalDataclasses(
    w,
    a,
    b,
  ),
  _ => throw _notANode(x),
};

bool _equalNamedTuples(_FastWalk w, MontyNamedTuple a, MontyNamedTuple b) =>
    _equalText(w, a.typeName, b.typeName) &&
    w._equalStrings(a.fieldNames, b.fieldNames) &&
    w._equalSeq(a.values, b.values);

bool _equalClassTypes(_FastWalk w, MontyClassType a, MontyClassType b) =>
    _equalText(w, a.name, b.name) &&
    _equalText(w, a.id, b.id) &&
    _classTypeFieldsEqual(a, b) &&
    w._equalAttrs(a.attrs, b.attrs);

bool _equalInstances(
  _FastWalk w,
  MontyClassInstance a,
  MontyClassInstance b,
) =>
    _equalText(w, a.instanceId, b.instanceId) &&
    w.equals(a.classType, b.classType) &&
    w._equalAttrs(a.attrs, b.attrs);

bool _equalDataclasses(_FastWalk w, MontyDataclass a, MontyDataclass b) =>
    _equalText(w, a.name, b.name) &&
    w._equalStrings(a.fieldNames, b.fieldNames) &&
    _dataclassFieldsEqual(a, b) &&
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
/// as the old asStringMap-based code did.
void _forEachProjectedChild(Object v, void Function(Object) f) {
  switch (v) {
    case MontyClassType(:final attrs) || MontyDataclass(:final attrs):
      _survivors(attrs).values.forEach(f);
    case MontyClassInstance(:final classType, :final attrs):
      f(classType);
      _survivors(attrs).values.forEach(f);
    case final MontyDict d when d.asStringMap != null:
      d.asStringMap?.values.forEach(f);
    default:
      _forEachChild(v, f);
  }
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

bool _stringsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final other = b.iterator;
  for (final s in a) {
    other.moveNext();
    if (s != other.current) return false;
  }

  return true;
}

bool _classTypeFieldsEqual(MontyClassType a, MontyClassType b) =>
    a.name == b.name &&
    a.id == b.id &&
    a.hostDefined == b.hostDefined &&
    a.isDataclass == b.isDataclass;

bool _dataclassFieldsEqual(MontyDataclass a, MontyDataclass b) =>
    a.name == b.name &&
    a.typeId == b.typeId &&
    a.frozen == b.frozen &&
    _stringsEqual(a.fieldNames, b.fieldNames);

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
    if (_kindOf(v) == _kFixed) return v.hashCode;

    return _memo[v] ?? (throw StateError('child hashed before its parent'));
  }

  int hash(Object root) {
    final kind = _kindOf(root);
    if (kind == _kFixed) return root.hashCode;
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
      if (k == _kFixed || _memo.containsKey(c)) return;
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
/// them: the [_lead] pair, then the values in step; when a value differs
/// and the map holds a repeated key, the entries as dict pairs.
final class _AttrsFrame extends _EqFrame {
  _AttrsFrame(super.x, super.y, this._a, this._b, this._lead)
    : _xs = _a.values.iterator,
      _ys = _b.values.iterator;

  final Map<String, MontyValue> _a;
  final Map<String, MontyValue> _b;
  final (Object, Object)? _lead;
  final Iterator<MontyValue> _xs;
  final Iterator<MontyValue> _ys;
  bool _onLead = false;
  bool _asPairs = false;

  @override
  bool? step(bool? last) {
    if (_asPairs) return last;
    if (last == false) {
      if (_onLead || !_hasRepeatedKey(_a)) return false;
      _asPairs = true;

      return ask(MontyDict(_attrPairs(_a)), MontyDict(_attrPairs(_b)));
    }
    if (last == null) {
      if (_lead case (final p, final q)) {
        _onLead = true;

        return ask(p, q);
      }
    }
    _onLead = false;
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
    if (_isLeafKind(kx) && _isLeafKind(ky)) return _leafEquals(x, y, kx, ky);
    if (kx != ky) return false;
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
    if (kx == _kFixed && ky == _kFixed) return x == y;
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
    (MontyList(items: final a), MontyList(items: final b)) ||
    (
      MontyTuple(items: final a),
      MontyTuple(items: final b),
    ) => a.length == b.length ? _SeqFrame(x, y, a, b) : null,
    (MontySet(items: final a), MontySet(items: final b)) ||
    (
      MontyFrozenSet(items: final a),
      MontyFrozenSet(items: final b),
    ) => a.length == b.length ? _SetFrame(x, y, a, _hasher, b) : null,
    (MontyDict(pairs: final a), MontyDict(pairs: final b)) =>
      a.length == b.length ? _DictFrame(x, y, a, _hasher, b) : null,
    _ => _structuredFrame(x, y),
  };

  _EqFrame? _structuredFrame(Object x, Object y) => switch ((x, y)) {
    (final MontyNamedTuple a, final MontyNamedTuple b) => _namedTupleFrame(
      a,
      b,
    ),
    (final MontyClassType a, final MontyClassType b) =>
      _classTypeFieldsEqual(a, b) ? _attrsFrame(a, b, a.attrs, b.attrs) : null,
    (final MontyClassInstance a, final MontyClassInstance b) =>
      a.instanceId == b.instanceId
          ? _attrsFrame(a, b, a.attrs, b.attrs, (a.classType, b.classType))
          : null,
    (final MontyDataclass a, final MontyDataclass b) =>
      _dataclassFieldsEqual(a, b) ? _attrsFrame(a, b, a.attrs, b.attrs) : null,
    _ => throw _notANode(x),
  };

  static _EqFrame? _namedTupleFrame(MontyNamedTuple a, MontyNamedTuple b) =>
      a.typeName == b.typeName &&
          _stringsEqual(a.fieldNames, b.fieldNames) &&
          a.values.length == b.values.length
      ? _SeqFrame(a, b, a.values, b.values)
      : null;

  /// Compares the [lead] pair first, then the attribute values by name.
  _EqFrame? _attrsFrame(
    Object x,
    Object y,
    Map<String, MontyValue> a,
    Map<String, MontyValue> b, [
    (Object, Object)? lead,
  ]) {
    if (a.length != b.length) return null;
    // As on the fast path: values in step when the keys come in the same
    // order, else the entries compared as dict pairs.
    if (_sameKeyOrder(a, b)) return _AttrsFrame(x, y, a, b, lead);

    return _SeqFrame(
      x,
      y,
      [?lead?.$1, MontyDict(_attrPairs(a))],
      [?lead?.$2, MontyDict(_attrPairs(b))],
    );
  }
}

// ---------------------------------------------------------------------------
// Projections: toJson and dartValue
// ---------------------------------------------------------------------------

/// Builds `toJson` or `dartValue` output.
///
/// Each node is built once per projection, so a node shared in the value is
/// one shared object in the output. A named tuple, a class instance and a
/// dataclass project to their `toJson` map in both projections, as before.
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
      kind == _kNamedTuple || kind == _kInstance || kind == _kDataclass;

  Map<Object, Object?> _memoFor({required bool json}) => json ? _json : _dart;

  Object? _leaf(Object v, int kind, {required bool toJson}) {
    final memo = _memoFor(json: toJson);
    if (kind == _kFixed || v is MontyString) {
      final m = v as MontyValue;
      final out = toJson ? m.toJson() : m.dartValue;
      // A shared leaf that projects to an object (a tagged float, a date)
      // is one object in the output too; a primitive has no identity.
      if (out == null || out is num || out is bool || out is String) {
        return out;
      }

      return memo.putIfAbsent(v, () => out);
    }
    if (memo.containsKey(v)) return memo[v];
    final m = v as MontyValue;

    return memo[v] = toJson ? m.toJson() : m.dartValue;
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
  /// it through asStringMap: the first position of each key, with its last
  /// value. Otherwise the entries form.
  Object _dict(MontyDict d, {required bool toJson}) {
    Object? get(Object c) => _child(c, toJson: toJson);
    final strings = d.asStringMap;
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

  /// Named tuples, class instances and dataclasses: always toJson maps.
  Object _buildStructured(Object v) => switch (v) {
    MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
      <String, Object?>{
        '__type': 'namedtuple',
        'type_name': typeName,
        'field_names': fieldNames,
        'values': [for (final c in values) _child(c, toJson: true)],
      },
    // Map<String, Object>, as the untyped literal it replaces inferred.
    MontyClassType(
      :final name,
      :final id,
      :final hostDefined,
      :final isDataclass,
      :final attrs,
    ) =>
      <String, Object>{
        'name': name,
        'id': id,
        'host_defined': hostDefined,
        'is_dataclass': isDataclass,
        'attrs': _attrsJson(attrs),
      },
    MontyClassInstance(:final classType, :final instanceId, :final attrs) =>
      <String, Object?>{
        '__type': 'class_instance',
        'class_type': _child(classType, toJson: true),
        'instance_id': instanceId,
        'attrs': _attrsJson(attrs),
      },
    MontyDataclass(
      :final name,
      :final typeId,
      :final fieldNames,
      :final attrs,
      :final frozen,
    ) =>
      <String, Object?>{
        '__type': 'dataclass',
        'name': name,
        'type_id': typeId,
        'field_names': fieldNames,
        'attrs': _attrsJson(attrs),
        'frozen': frozen,
      },
    _ => throw _notANode(v),
  };

  /// An attribute map in the dict envelope, as `MontyDict.ofStrings` wrote it.
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
  final DateTime dt => _fromDartDateTime(dt.toUtc()),
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

MontyDateTime _fromDartDateTime(DateTime u) => MontyDateTime(
  year: u.year,
  month: u.month,
  day: u.day,
  hour: u.hour,
  minute: u.minute,
  second: u.second,
  // Dart splits the fraction into milliseconds and microseconds; Python's
  // microsecond field holds both.
  microsecond: u.millisecond * 1000 + u.microsecond,
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
