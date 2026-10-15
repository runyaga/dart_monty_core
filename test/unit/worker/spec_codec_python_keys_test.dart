// Spec tests for Python key equality as the reader applies it to dictionary
// keys and set and frozenset members: which separately decoded nodes collapse
// into one entry, which stay apart, and which are refused as unhashable. Each
// test name starts with the requirement id it asserts, so a mutation run can
// select it with `-N 'REQ-<id>:'`. Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:test/test.dart';

import '_arena_fixtures.dart';

MontyValue _decode(List<pb.MontyNode> nodes) {
  final arena = pb.Arena.fromBuffer(
    pb.Arena(nodeCount: nodes.length, nodes: nodes).writeToBuffer(),
  );

  return ArenaReader(arena)[nodes.length - 1];
}

String _refusal(List<pb.MontyNode> nodes) {
  try {
    _decode(nodes);
  } on FormatException catch (e) {
    return e.message;
  }
  fail('decoding was not refused');
}

/// The number of members a set built over [members] keeps.
int _setSize(List<pb.MontyNode> members) =>
    (_decode([
              ...members,
              set([for (var i = 0; i < members.length; i++) i]),
            ])
            as MontySet)
        .items
        .length;

int _frozenSize(List<pb.MontyNode> members) =>
    (_decode([
              ...members,
              frozen([for (var i = 0; i < members.length; i++) i]),
            ])
            as MontyFrozenSet)
        .items
        .length;

/// The number of entries a dict keyed by [keys] keeps.
int _dictSize(List<pb.MontyNode> keys) =>
    (_decode([
              ...keys,
              n('v'),
              dict([for (var i = 0; i < keys.length; i++) (i, keys.length)]),
            ])
            as MontyDict)
        .pairs
        .length;

String _unhashable(String type) => "TypeError: unhashable type: '$type'";

void main() {
  group('complex keys', () {
    test('REQ-MontyComplex-16: zero imag, incl. negative, is its real key', () {
      // true, 1, 1 (bigint arm), 1.0, 1+0j, 1-0j: one Python key.
      final same = [
        n(true),
        n(1),
        pb.MontyNode(
          bigint: pb.BigInt(magnitude: magnitudeBytes(BigInt.one)),
        ),
        floatNode(1),
        complexNode(real: 1, imag: 0),
        complexNode(real: 1, imag: -0),
      ];
      expect(_setSize(same), 1);
      expect(_frozenSize(same), 1);
      expect(_dictSize(same), 1);
      // A float and a bigint are equal as Python compares them: 1e30 is
      // 1000000000000000019884624838656 exactly.
      final exact = BigInt.parse('1000000000000000019884624838656');
      expect(
        _setSize([
          floatNode(1e30),
          pb.MontyNode(bigint: pb.BigInt(magnitude: magnitudeBytes(exact))),
          complexNode(real: 1e30, imag: -0),
        ]),
        1,
      );
      // Negative zero alone is zero.
      expect(_setSize([n(0), complexNode(real: 0, imag: -0), n(-0.0)]), 1);
    });

    test('REQ-MontyComplex-16: otherwise component by component', () {
      expect(
        _setSize([
          complexNode(real: 1, imag: 2),
          complexNode(real: 1, imag: 2),
        ]),
        1,
      );
      expect(
        _setSize([
          complexNode(real: 1, imag: 2),
          complexNode(real: 2, imag: 1),
        ]),
        2,
      );
      expect(
        _setSize([
          complexNode(real: 1, imag: 2),
          complexNode(real: 1, imag: 3),
        ]),
        2,
      );
      expect(
        _setSize([
          complexNode(real: 1, imag: 2),
          complexNode(real: 3, imag: 2),
        ]),
        2,
      );
      expect(_setSize([n(1), complexNode(real: 1, imag: 2)]), 2);
      // A NaN component equals nothing, not even another node's NaN.
      const nan = double.nan;
      expect(
        _setSize([
          complexNode(real: nan, imag: 1),
          complexNode(real: nan, imag: 1),
        ]),
        2,
      );
      expect(
        _setSize([
          complexNode(real: 1, imag: nan),
          complexNode(real: 1, imag: nan),
        ]),
        2,
      );
    });
  });

  group('NaN floats', () {
    // Node 0 and 1 are distinct NaN nodes; the same node twice is one key.
    test('REQ-MontyFloat-12: dict, set and frozenset keys', () {
      expect(_dictSize([n(double.nan), n(double.nan)]), 2);
      expect(_setSize([n(double.nan), n(double.nan)]), 2);
      expect(_frozenSize([n(double.nan), n(double.nan)]), 2);

      final dictRepeat =
          _decode([
                n(double.nan),
                n('a'),
                n('b'),
                dict([(0, 1), (0, 2)]),
              ])
              as MontyDict;
      expect(dictRepeat.pairs, hasLength(1));
      expect(
        _decode([
              n(double.nan),
              set([0, 0]),
            ])
            as MontySet,
        isA<MontySet>().having((s) => s.items.length, 'length', 1),
      );
      expect(
        _decode([
              n(double.nan),
              frozen([0, 0, 0]),
            ])
            as MontyFrozenSet,
        isA<MontyFrozenSet>().having((s) => s.items.length, 'length', 1),
      );
      // Mixed: two repeats of one node and one other NaN node.
      expect(
        (_decode([
                  n(double.nan),
                  n(double.nan),
                  set([0, 1, 0, 1]),
                ])
                as MontySet)
            .items,
        hasLength(2),
      );
    });

    test('REQ-MontyFrozenSet-10: separate NaN nodes stay, repeats merge', () {
      expect(_frozenSize([n(double.nan), n(double.nan)]), 2);
      expect(_frozenSize([n(double.nan), n(double.nan), n(double.nan)]), 3);
      final merged =
          _decode([
                n(double.nan),
                n(double.nan),
                frozen([0, 1, 0, 1, 1]),
              ])
              as MontyFrozenSet;
      expect(merged.items, hasLength(2));
      // A NaN does not merge with a number.
      expect(_frozenSize([n(double.nan), floatNode(0), n(1.5)]), 3);
    });
  });

  group('exceptions and file handles are keyed by node, not by fields', () {
    final exceptionNodes = [
      exception('ValueError', 'm'),
      exception('ValueError', 'm'),
    ];
    final fileNodes = [file('r'), file('r')];

    test('REQ-MontyExceptionValue-12: dictionary keys', () {
      // Two nodes equal in Dart: two Python keys.
      expect(
        MontyExceptionValue('ValueError', 'm'),
        MontyExceptionValue('ValueError', 'm'),
      );
      final decoded =
          _decode([
                ...exceptionNodes,
                n(1),
                n(2),
                dict([(0, 2), (1, 3)]),
              ])
              as MontyDict;
      expect(decoded.pairs, hasLength(2));
      expect(decoded.pairs[0].$1, decoded.pairs[1].$1);
      // The same node twice: one key, the later value kept.
      final repeat =
          _decode([
                exceptionNodes[0],
                n(1),
                n(2),
                dict([(0, 1), (0, 2)]),
              ])
              as MontyDict;
      expect(repeat.pairs, [
        (MontyExceptionValue('ValueError', 'm'), const MontyInt(2)),
      ]);
    });

    test('REQ-MontyFileHandle-14: dict, set and frozenset members', () {
      expect(_dictSize(fileNodes), 2);
      expect(_setSize(fileNodes), 2);
      expect(_frozenSize(fileNodes), 2);
      expect(
        _decode([
              file('r'),
              set([0, 0]),
            ])
            as MontySet,
        isA<MontySet>().having((s) => s.items.length, 'length', 1),
      );
      expect(
        _decode([
              file('r'),
              frozen([0, 0]),
            ])
            as MontyFrozenSet,
        isA<MontyFrozenSet>().having((s) => s.items.length, 'length', 1),
      );
      expect(
        (_decode([
                  file('r'),
                  n(1),
                  dict([(0, 1), (0, 1)]),
                ])
                as MontyDict)
            .pairs,
        hasLength(1),
      );
    });

    test('REQ-MontyFrozenSet-11: frozenset elements', () {
      expect(_frozenSize(exceptionNodes), 2);
      expect(_frozenSize(fileNodes), 2);
      expect(_frozenSize([...exceptionNodes, ...fileNodes]), 4);
      final repeat =
          _decode([
                exception('ValueError', 'm'),
                file('r'),
                frozen([0, 1, 0, 1]),
              ])
              as MontyFrozenSet;
      expect(repeat.items, hasLength(2));
    });
  });

  group('tuples, named tuples and frozensets as keys', () {
    final list0 = list([]);
    final dict0 = dict([]);

    // Each shape holds members [bad] over node refs 0..k.
    List<pb.MontyNode> inSet(
      pb.MontyNode Function(List<int>) shape,
      List<pb.MontyNode> members,
    ) => [
      ...members,
      shape([for (var i = 0; i < members.length; i++) i]),
      set([members.length]),
    ];

    final shapes = <String, pb.MontyNode Function(List<int>)>{
      'tuple': tuple,
      'named tuple': (items) => namedTuple('P', [
        for (var i = 0; i < items.length; i++) 'f$i',
      ], items),
      'frozenset': frozen,
    };

    test('REQ-MontyDict-26: first unhashable member, stored order', () {
      for (final MapEntry(key: name, value: shape) in shapes.entries) {
        expect(
          _refusal(inSet(shape, [n(1), list0, dict0])),
          _unhashable('list'),
          reason: name,
        );
        expect(
          _refusal(inSet(shape, [dict0, list0])),
          _unhashable('dict'),
          reason: name,
        );
        expect(
          _refusal(inSet(shape, [n(1), set([]), list0])),
          _unhashable('set'),
          reason: name,
        );
        // As a dictionary key.
        final members = [n(1), list0, dict0];
        expect(
          _refusal([
            ...members,
            shape([0, 1, 2]),
            n('v'),
            dict([(3, 4)]),
          ]),
          _unhashable('list'),
          reason: name,
        );
      }
      // Recursively: tuple in tuple in frozenset.
      expect(
        _refusal([
          list0,
          tuple([0]),
          tuple([1]),
          frozen([2]),
          n('v'),
          dict([(3, 4)]),
        ]),
        _unhashable('list'),
      );
      // Hashable members are accepted, whatever the shape.
      for (final shape in shapes.values) {
        expect(
          (_decode([
                    n(1),
                    n('x'),
                    shape([0, 1]),
                    n('v'),
                    dict([(2, 3)]),
                  ])
                  as MontyDict)
              .pairs,
          hasLength(1),
        );
      }
    });

    test(
      'REQ-MontySet-21: a recursively unhashable element refuses the set',
      () {
        for (final MapEntry(key: name, value: shape) in shapes.entries) {
          expect(
            _refusal([
              list0,
              shape([0]),
              set([1]),
            ]),
            _unhashable('list'),
            reason: name,
          );
          expect(
            _refusal([
              dict0,
              tuple([0]),
              shape([1]),
              set([2]),
            ]),
            _unhashable('dict'),
            reason: name,
          );
          expect(
            _refusal([
              n(1),
              set([]),
              shape([0, 1]),
              set([2]),
            ]),
            _unhashable('set'),
            reason: name,
          );
          // The same element with hashable members is accepted.
          expect(
            (_decode([
                      n(1),
                      n('x'),
                      shape([0, 1]),
                      set([2]),
                    ])
                    as MontySet)
                .items,
            hasLength(1),
            reason: name,
          );
        }
      },
    );

    test('REQ-MontyFrozenSet-21: the message names the first member', () {
      expect(
        _refusal([
          dict0,
          list0,
          frozen([0, 1]),
        ]),
        _unhashable('dict'),
      );
      expect(
        _refusal([
          list0,
          dict0,
          frozen([0, 1]),
        ]),
        _unhashable('list'),
      );
      expect(
        _refusal([
          n(1),
          set([]),
          list0,
          frozen([0, 1, 2]),
        ]),
        _unhashable('set'),
      );
      // Nested frozenset members are judged in order too.
      expect(
        _refusal([
          dict0,
          list0,
          frozen([0, 1]),
          frozen([2]),
        ]),
        _unhashable('dict'),
      );
    });

    test('REQ-MontyNamedTuple-11: a key equal to the tuple of its members', () {
      // tuple (1, 2), P(1, 2) and Q(x, y = 1, 2): one key.
      final decoded =
          _decode([
                n(1),
                n(2),
                tuple([0, 1]),
                namedTuple('P', ['a', 'b'], [0, 1]),
                namedTuple('m.Q', ['x', 'y'], [0, 1]),
                n('v'),
                dict([(2, 5), (3, 5), (4, 5)]),
              ])
              as MontyDict;
      expect(decoded.pairs, hasLength(1));
      // Different members stay apart.
      expect(
        _dictSize([
          tuple([]),
          namedTuple('P', [], []),
        ]),
        1,
      );
      final apart =
          _decode([
                n(1),
                n(2),
                namedTuple('P', ['a', 'b'], [0, 1]),
                namedTuple('P', ['a', 'b'], [1, 0]),
                n('v'),
                dict([(2, 4), (3, 4)]),
              ])
              as MontyDict;
      expect(apart.pairs, hasLength(2));
      // Hashable only when every member is.
      expect(
        _refusal([
          list([]),
          namedTuple('P', ['a'], [0]),
          n('v'),
          dict([(1, 2)]),
        ]),
        _unhashable('list'),
      );
      expect(
        _refusal([
          n(1),
          dict([]),
          namedTuple('P', ['a', 'b'], [0, 1]),
          n('v'),
          dict([(2, 3)]),
        ]),
        _unhashable('dict'),
      );
    });
  });
}
