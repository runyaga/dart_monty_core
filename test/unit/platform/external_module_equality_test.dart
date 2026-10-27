// The Python-shaped equality of an ExternalModule: upstream compares the
// attribute dictionaries with Python's dictionary equality, so a list or a
// map attribute matches another one with the same contents, not only the
// very same object.
//
// Upstream (monty v1.2.0):
//   crates/monty-proto/src/python/external_module.rs:72 -- `fn __eq__`.
//   crates/monty-proto/src/python/external_module.rs:74 -- the attributes
//     are compared with Python's dictionary equality.
//   crates/monty-python/tests/test_external_modules.py:169 --
//     `def test_the_module_object_is_frozen():`.
//   crates/monty-python/tests/test_external_modules.py:178 --
//     `assert tools == ExternalModule({'add': add}, stubs=ADD_STUB, id=uid)`.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

/// The id the modules a test compares share.
const _moduleId = '9e107669-c31b-4d0f-8b76-2f0e2a4b5a03';

/// Another id, so that a module with another identity is at hand.
const _otherModuleId = '1b4e28ba-2fa1-11d2-883f-0016d3cca427';

/// The recursion a cyclic comparison ends in. Python raises a
/// `RecursionError` there; this Dart representation of it is a [StateError]
/// with this message.
final Matcher _recursiveEquality = throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'message',
    'recursive ExternalModule equality',
  ),
);

/// A leaf whose own equality says it matches nothing: not another one, and
/// not itself either.
@immutable
class _UnequalLeaf {
  const _UnequalLeaf();

  @override
  bool operator ==(Object other) => false;

  @override
  int get hashCode => 1;

  @override
  String toString() => '_UnequalLeaf()';
}

/// A leaf whose own equality says that two instances sharing a tag match,
/// the way a host's own type decides.
@immutable
class _EqualLeaf {
  const _EqualLeaf(this.tag);

  /// What the two instances a test compares share.
  final Object tag;

  @override
  bool operator ==(Object other) => other is _EqualLeaf && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => '_EqualLeaf($tag)';
}

void main() {
  test(
    'ExternalModule structurally compares Python-shaped attribute values',
    () {
      _metadataRules();
      _containerRules();
      _nestedModuleRules();
      _recursiveRules();
    },
  );
}

/// The id and the stubs are part of the equality, and a protected attribute
/// counts like any other attribute.
void _metadataRules() {
  // Upstream's `__eq__` compares the id and the stubs before the attributes
  // (external_module.rs:74).
  final base = ExternalModule(
    {'VERSION': 3},
    stubs: 'def add(a: int, b: int) -> int: ...',
    id: _moduleId,
  );
  final twin = ExternalModule(
    {'VERSION': 3},
    stubs: 'def add(a: int, b: int) -> int: ...',
    id: _moduleId,
  );
  final otherId = ExternalModule(
    {'VERSION': 3},
    stubs: 'def add(a: int, b: int) -> int: ...',
    id: _otherModuleId,
  );
  final otherStubs = ExternalModule({'VERSION': 3}, stubs: '', id: _moduleId);
  expect(base == twin, isTrue);
  expect(twin == base, isTrue);
  expect(base == otherId, isFalse);
  expect(otherId == base, isFalse);
  expect(base == otherStubs, isFalse);
  expect(otherStubs == base, isFalse);

  // A protected attribute is an attribute: its name and its value count, as
  // they do in the dictionary upstream compares.
  final protectedBase = ExternalModule({'_p': 1}, id: _moduleId);
  final protectedChanged = ExternalModule({'_p': 2}, id: _moduleId);
  final protectedDropped = ExternalModule({}, id: _moduleId);
  expect(protectedBase == protectedChanged, isFalse);
  expect(protectedChanged == protectedBase, isFalse);
  expect(protectedBase == protectedDropped, isFalse);
  expect(protectedDropped == protectedBase, isFalse);
}

/// The attribute values are compared the way Python compares them: a list
/// in order, a map in any order, a null like any other value.
void _containerRules() {
  // A list attribute is compared element by element, in order: Python's list
  // equality.
  final listBase = ExternalModule({
    'x': <Object?>[1, 2],
  }, id: _moduleId);
  final listTwin = ExternalModule({
    'x': <Object?>[1, 2],
  }, id: _moduleId);
  final listReordered = ExternalModule({
    'x': <Object?>[2, 1],
  }, id: _moduleId);
  final listLonger = ExternalModule({
    'x': <Object?>[1, 2, 3],
  }, id: _moduleId);
  expect(listBase == listTwin, isTrue);
  expect(listTwin == listBase, isTrue);
  expect(listBase == listReordered, isFalse);
  expect(listReordered == listBase, isFalse);
  expect(listBase == listLonger, isFalse);
  expect(listLonger == listBase, isFalse);

  // A map attribute is compared key by key, in any order: Python's dictionary
  // equality ignores the insertion order.
  final mapBase = ExternalModule({
    'x': <String, Object?>{'a': 1, 'b': 2},
  }, id: _moduleId);
  final mapReordered = ExternalModule({
    'x': <String, Object?>{'b': 2, 'a': 1},
  }, id: _moduleId);
  final mapChanged = ExternalModule({
    'x': <String, Object?>{'a': 1, 'b': 3},
  }, id: _moduleId);
  final mapRenamed = ExternalModule({
    'x': <String, Object?>{'a': 1, 'c': 2},
  }, id: _moduleId);
  expect(mapBase == mapReordered, isTrue);
  expect(mapReordered == mapBase, isTrue);
  expect(mapBase == mapChanged, isFalse);
  expect(mapChanged == mapBase, isFalse);
  expect(mapBase == mapRenamed, isFalse);
  expect(mapRenamed == mapBase, isFalse);

  // A null value is a value like any other: the entries after it are still
  // compared, and a null under one name is not a null under another name.
  final nulls = ExternalModule({'a': null, 'b': 1}, id: _moduleId);
  final nullsLater = ExternalModule({'a': null, 'b': 2}, id: _moduleId);
  final nullsRenamed = ExternalModule({'c': null, 'b': 1}, id: _moduleId);
  final nullsSame = ExternalModule({'b': 1, 'a': null}, id: _moduleId);
  expect(nulls == nullsLater, isFalse);
  expect(nullsLater == nulls, isFalse);
  expect(nulls == nullsRenamed, isFalse);
  expect(nullsRenamed == nulls, isFalse);
  expect(nulls == nullsSame, isTrue);
  expect(nullsSame == nulls, isTrue);

  // The same holds inside a container: a null does not end the comparison of
  // the entries after it, and a null under one key is not a null under
  // another key.
  final nullList = ExternalModule({
    'x': <Object?>[null, 1],
  }, id: _moduleId);
  final nullListLater = ExternalModule({
    'x': <Object?>[null, 2],
  }, id: _moduleId);
  final nullListSame = ExternalModule({
    'x': <Object?>[null, 1],
  }, id: _moduleId);
  expect(nullList == nullListLater, isFalse);
  expect(nullListLater == nullList, isFalse);
  expect(nullList == nullListSame, isTrue);
  expect(nullListSame == nullList, isTrue);

  final nullMap = ExternalModule({
    'x': <String, Object?>{'a': null, 'b': 1},
  }, id: _moduleId);
  final nullMapLater = ExternalModule({
    'x': <String, Object?>{'a': null, 'b': 2},
  }, id: _moduleId);
  final nullMapRenamed = ExternalModule({
    'x': <String, Object?>{'c': null, 'b': 1},
  }, id: _moduleId);
  final nullMapSame = ExternalModule({
    'x': <String, Object?>{'b': 1, 'a': null},
  }, id: _moduleId);
  expect(nullMap == nullMapLater, isFalse);
  expect(nullMapLater == nullMap, isFalse);
  expect(nullMap == nullMapRenamed, isFalse);
  expect(nullMapRenamed == nullMap, isFalse);
  expect(nullMap == nullMapSame, isTrue);
  expect(nullMapSame == nullMap, isTrue);

  // A null key is a key like any other: the entries after it are still
  // compared, and a null key is not a missing key.
  final nullKey = ExternalModule({
    'x': <Object?, Object?>{null: 1, 'b': 2},
  }, id: _moduleId);
  final nullKeyLater = ExternalModule({
    'x': <Object?, Object?>{null: 1, 'b': 3},
  }, id: _moduleId);
  final nullKeyRenamed = ExternalModule({
    'x': <Object?, Object?>{'z': 1, 'b': 2},
  }, id: _moduleId);
  final nullKeySame = ExternalModule({
    'x': <Object?, Object?>{null: 1, 'b': 2},
  }, id: _moduleId);
  expect(nullKey == nullKeyLater, isFalse);
  expect(nullKeyLater == nullKey, isFalse);
  expect(nullKey == nullKeyRenamed, isFalse);
  expect(nullKeyRenamed == nullKey, isFalse);
  expect(nullKey == nullKeySame, isTrue);
  expect(nullKeySame == nullKey, isTrue);

  // A null key holding a null is a null under another name, not the same
  // one.
  final nullKeyNull = ExternalModule({
    'x': <Object?, Object?>{null: null, 'b': 1},
  }, id: _moduleId);
  final nullKeyNullRenamed = ExternalModule({
    'x': <Object?, Object?>{'z': null, 'b': 1},
  }, id: _moduleId);
  expect(nullKeyNull == nullKeyNullRenamed, isFalse);
  expect(nullKeyNullRenamed == nullKeyNull, isFalse);

  // One acyclic child shared by two attributes is not a recursion: it is
  // walked twice, and it matches the equal copies.
  final sharedChild = <Object?>[1, 2];
  final sharedTwice = ExternalModule({
    'x': sharedChild,
    'y': sharedChild,
  }, id: _moduleId);
  final copiedTwice = ExternalModule({
    'x': <Object?>[1, 2],
    'y': <Object?>[1, 2],
  }, id: _moduleId);
  expect(sharedTwice == copiedTwice, isTrue);
  expect(copiedTwice == sharedTwice, isTrue);

  // The same inside a list and inside a map.
  final sharedInList = ExternalModule({
    'x': <Object?>[sharedChild, sharedChild],
  }, id: _moduleId);
  final copiedInList = ExternalModule({
    'x': <Object?>[
      <Object?>[1, 2],
      <Object?>[1, 2],
    ],
  }, id: _moduleId);
  expect(sharedInList == copiedInList, isTrue);
  expect(copiedInList == sharedInList, isTrue);

  final sharedInMap = ExternalModule({
    'x': <String, Object?>{'p': sharedChild, 'q': sharedChild},
  }, id: _moduleId);
  final copiedInMap = ExternalModule({
    'x': <String, Object?>{
      'p': <Object?>[1, 2],
      'q': <Object?>[1, 2],
    },
  }, id: _moduleId);
  expect(sharedInMap == copiedInMap, isTrue);
  expect(copiedInMap == sharedInMap, isTrue);

  // A container both modules share is compared by identity and is never
  // walked: the leaf inside says it matches nothing, so walking the shared
  // container would make the two modules unequal.
  final sharedList = <Object?>[const _UnequalLeaf()];
  final sharedMap = <String, Object?>{'k': const _UnequalLeaf()};
  final sharesList = ExternalModule({'x': sharedList}, id: _moduleId);
  final sharesListAgain = ExternalModule({'x': sharedList}, id: _moduleId);
  final sharesMap = ExternalModule({'x': sharedMap}, id: _moduleId);
  final sharesMapAgain = ExternalModule({'x': sharedMap}, id: _moduleId);
  expect(sharesList == sharesListAgain, isTrue);
  expect(sharesListAgain == sharesList, isTrue);
  expect(sharesMap == sharesMapAgain, isTrue);
  expect(sharesMapAgain == sharesMap, isTrue);
}

/// A nested module is compared by its own equality, and a leaf and a map
/// key are compared with their own `==`.
void _nestedModuleRules() {
  // A nested module is compared by its own equality: its id, its stubs and
  // its attributes.
  final subBase = ExternalModule(
    {'VERSION': 1},
    stubs: 'sub stubs',
    id: _moduleId,
  );
  final subTwin = ExternalModule(
    {'VERSION': 1},
    stubs: 'sub stubs',
    id: _moduleId,
  );
  final subOtherId = ExternalModule(
    {'VERSION': 1},
    stubs: 'sub stubs',
    id: _otherModuleId,
  );
  final subOtherStubs = ExternalModule(
    {'VERSION': 1},
    stubs: '',
    id: _moduleId,
  );
  final subOtherValue = ExternalModule(
    {'VERSION': 2},
    stubs: 'sub stubs',
    id: _moduleId,
  );
  final holdsSub = ExternalModule({'pkg': subBase}, id: _moduleId);
  final holdsSubTwin = ExternalModule({'pkg': subTwin}, id: _moduleId);
  final holdsSubOtherId = ExternalModule({'pkg': subOtherId}, id: _moduleId);
  final holdsSubOtherStubs = ExternalModule({
    'pkg': subOtherStubs,
  }, id: _moduleId);
  final holdsSubOtherValue = ExternalModule({
    'pkg': subOtherValue,
  }, id: _moduleId);
  expect(holdsSub == holdsSubTwin, isTrue);
  expect(holdsSubTwin == holdsSub, isTrue);
  expect(holdsSub == holdsSubOtherId, isFalse);
  expect(holdsSubOtherId == holdsSub, isFalse);
  expect(holdsSub == holdsSubOtherStubs, isFalse);
  expect(holdsSubOtherStubs == holdsSub, isFalse);
  expect(holdsSub == holdsSubOtherValue, isFalse);
  expect(holdsSubOtherValue == holdsSub, isFalse);

  // The containers a nested module holds are compared structurally too.
  final nestedListBase = ExternalModule({
    'pkg': ExternalModule({
      'x': <Object?>[1, 2],
    }, id: _moduleId),
  }, id: _moduleId);
  final nestedListTwin = ExternalModule({
    'pkg': ExternalModule({
      'x': <Object?>[1, 2],
    }, id: _moduleId),
  }, id: _moduleId);
  expect(nestedListBase == nestedListTwin, isTrue);
  expect(nestedListTwin == nestedListBase, isTrue);

  // A leaf is compared with its own `==`, as Python compares two objects of
  // the host's own type.
  final leafTag = Object();
  final otherTag = Object();
  final leafOne = _EqualLeaf(leafTag);
  final leafTwo = _EqualLeaf(leafTag);
  final leafOther = _EqualLeaf(otherTag);
  expect(identical(leafOne, leafTwo), isFalse);
  final holdsLeafOne = ExternalModule({'x': leafOne}, id: _moduleId);
  final holdsLeafTwo = ExternalModule({'x': leafTwo}, id: _moduleId);
  final holdsLeafOther = ExternalModule({'x': leafOther}, id: _moduleId);
  expect(holdsLeafOne == holdsLeafTwo, isTrue);
  expect(holdsLeafTwo == holdsLeafOne, isTrue);
  expect(holdsLeafOne == holdsLeafOther, isFalse);
  expect(holdsLeafOther == holdsLeafOne, isFalse);

  // A map key is compared with its own `==` too, as Python compares two
  // hashable keys.
  final keyOne = _EqualLeaf(leafTag);
  final keyTwo = _EqualLeaf(leafTag);
  final keyOther = _EqualLeaf(otherTag);
  final mapKeyBase = ExternalModule({
    'x': <Object?, Object?>{keyOne: 'value'},
  }, id: _moduleId);
  final mapKeyTwin = ExternalModule({
    'x': <Object?, Object?>{keyTwo: 'value'},
  }, id: _moduleId);
  final mapKeyOther = ExternalModule({
    'x': <Object?, Object?>{keyOther: 'value'},
  }, id: _moduleId);
  expect(mapKeyBase == mapKeyTwin, isTrue);
  expect(mapKeyTwin == mapKeyBase, isTrue);
  expect(mapKeyBase == mapKeyOther, isFalse);
  expect(mapKeyOther == mapKeyBase, isFalse);
}

/// A cyclic value is compared as Python compares it: the very same one is
/// equal, an earlier difference is answered before the recursion, and two
/// separately allocated cycles of the same shape never end.
void _recursiveRules() {
  // The very same cyclic value in two modules is equal: Python compares one
  // object with itself, and never walks into the cycle.
  final sharedCyclicList = <Object?>[];
  sharedCyclicList.add(sharedCyclicList);
  final sharedCyclicMap = <String, Object?>{};
  sharedCyclicMap['self'] = sharedCyclicMap;

  final holdsSharedCyclicList = ExternalModule({
    'x': sharedCyclicList,
  }, id: _moduleId);
  final holdsSharedCyclicListAgain = ExternalModule({
    'x': sharedCyclicList,
  }, id: _moduleId);
  expect(holdsSharedCyclicList == holdsSharedCyclicListAgain, isTrue);
  expect(holdsSharedCyclicListAgain == holdsSharedCyclicList, isTrue);

  final holdsSharedCyclicMap = ExternalModule({
    'x': sharedCyclicMap,
  }, id: _moduleId);
  final holdsSharedCyclicMapAgain = ExternalModule({
    'x': sharedCyclicMap,
  }, id: _moduleId);
  expect(holdsSharedCyclicMap == holdsSharedCyclicMapAgain, isTrue);
  expect(holdsSharedCyclicMapAgain == holdsSharedCyclicMap, isTrue);

  // Two separately allocated cycles of the same shape are a Python
  // `RecursionError`: the comparison never ends, and this Dart
  // representation of it is a `StateError`.
  final selfList = <Object?>[];
  selfList.add(selfList);
  final selfListOther = <Object?>[];
  selfListOther.add(selfListOther);
  final selfMap = <String, Object?>{};
  selfMap['self'] = selfMap;
  final selfMapOther = <String, Object?>{};
  selfMapOther['self'] = selfMapOther;

  // An unequal value before the cycle is answered before the recursion is
  // reached: the comparison stops at the first difference, and never walks
  // into the cycle.
  final earlyList = ExternalModule({
    'a': 1,
    'x': selfList,
  }, id: _moduleId);
  final earlyListChanged = ExternalModule({
    'a': 2,
    'x': selfListOther,
  }, id: _moduleId);
  expect(earlyList == earlyListChanged, isFalse);
  expect(earlyListChanged == earlyList, isFalse);

  final earlyMap = ExternalModule({
    'a': 1,
    'x': selfMap,
  }, id: _moduleId);
  final earlyMapChanged = ExternalModule({
    'a': 2,
    'x': selfMapOther,
  }, id: _moduleId);
  expect(earlyMap == earlyMapChanged, isFalse);
  expect(earlyMapChanged == earlyMap, isFalse);

  // The same inside a container: the first element differs, so the cyclic
  // one after it is never reached.
  final earlyInList = ExternalModule({
    'x': <Object?>[1, selfList],
  }, id: _moduleId);
  final earlyInListChanged = ExternalModule({
    'x': <Object?>[2, selfListOther],
  }, id: _moduleId);
  expect(earlyInList == earlyInListChanged, isFalse);
  expect(earlyInListChanged == earlyInList, isFalse);

  // The cycles themselves, each compared with its own counterpart.
  final holdsSelfList = ExternalModule({'x': selfList}, id: _moduleId);
  final holdsSelfListOther = ExternalModule({
    'x': selfListOther,
  }, id: _moduleId);
  expect(() => holdsSelfList == holdsSelfListOther, _recursiveEquality);
  expect(() => holdsSelfListOther == holdsSelfList, _recursiveEquality);

  final holdsSelfMap = ExternalModule({'x': selfMap}, id: _moduleId);
  final holdsSelfMapOther = ExternalModule({
    'x': selfMapOther,
  }, id: _moduleId);
  expect(() => holdsSelfMap == holdsSelfMapOther, _recursiveEquality);
  expect(() => holdsSelfMapOther == holdsSelfMap, _recursiveEquality);

  // A cycle that runs through a module: the module holds a list that holds
  // the module back.
  final mediatedList = <Object?>[];
  final mediatedModule = ExternalModule({'x': mediatedList}, id: _moduleId);
  mediatedList.add(mediatedModule);
  final mediatedListOther = <Object?>[];
  final mediatedModuleOther = ExternalModule({
    'x': mediatedListOther,
  }, id: _moduleId);
  mediatedListOther.add(mediatedModuleOther);
  expect(() => mediatedModule == mediatedModuleOther, _recursiveEquality);
  expect(() => mediatedModuleOther == mediatedModule, _recursiveEquality);
}
