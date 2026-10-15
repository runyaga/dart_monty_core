// Spec tests for the arena reader: what a decoded value is (wrapper type,
// identity, immutability, attribute filtering, field presence). Each test
// name starts with the requirement id it asserts, so a mutation run can
// select it with `-N 'REQ-<id>:'`. Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_arena_fixtures.dart';
import '_spec_codec_support.dart';

/// The arena after a wire round trip, so field presence survives as it
/// would from the worker.
ArenaReader _reader(List<pb.MontyNode> nodes) => ArenaReader(
  pb.Arena.fromBuffer(
    pb.Arena(nodeCount: nodes.length, nodes: nodes).writeToBuffer(),
  ),
);

MontyValue _decode(List<pb.MontyNode> nodes, [int? root]) =>
    _reader(nodes)[root ?? nodes.length - 1];

/// An integer on the `int` wire arm (zig-zag), whatever its size.
pb.MontyNode _intArm(BigInt v) =>
    pb.MontyNode(int_5: zigzagEncode(Int64.parseInt('$v')));

/// An integer on the `bigint` wire arm, even when it would fit the int arm.
pb.MontyNode _bigArm(BigInt v) {
  final big = pb.BigInt(magnitude: magnitudeBytes(v.abs()));
  if (v.isNegative) big.negative = true;

  return pb.MontyNode(bigint: big);
}

String _formatMessage(List<pb.MontyNode> nodes) {
  try {
    _decode(nodes);
  } on FormatException catch (e) {
    return e.message;
  }
  fail('decoding was not refused');
}

/// The text of upstream's refusal of a name that is not an identifier.
const _notIdentifier =
    'ValueError: Type names and field names must be valid identifiers: ';

void main() {
  final two53 = BigInt.one << 53;

  group('integers', () {
    test('REQ-MontyBigInt-5: MontyInt up to 2^53, MontyBigInt above', () {
      for (final (value, big) in [
        (BigInt.zero, false),
        (BigInt.one, false),
        (two53 - BigInt.one, false),
        (two53, false),
        (-two53, false),
        (two53 + BigInt.one, true),
        (-two53 - BigInt.one, true),
        (BigInt.one << 60, true),
        (-(BigInt.one << 62), true),
      ]) {
        for (final (arm, node) in [
          ('int', _intArm(value)),
          ('bigint', _bigArm(value)),
        ]) {
          final decoded = _decode([node]);
          final reason = '$value on the $arm arm';
          if (big) {
            expect(decoded, isBigInt, reason: reason);
            expect((decoded as MontyBigInt).value, value, reason: reason);
          } else {
            expect(decoded, isInt, reason: reason);
            expect((decoded as MontyInt).value, value.toInt(), reason: reason);
          }
        }
      }
    });

    test(
      'REQ-MontyInt-7: a large integer decodes to its exact MontyBigInt',
      () {
        final value = (BigInt.one << 60) + BigInt.from(12345);
        final decoded = _decode([_intArm(value)]);
        expect(decoded, isBigInt);
        expect(decoded.dartValue, isA<BigInt>());
        expect(decoded.dartValue, value);
        expect(decoded.toString(), 'MontyBigInt(1152921504606859321)');
        // The writer's output reads back as the same MontyBigInt.
        final writer = ArenaWriter();
        final root = writer.add(MontyBigInt(value));
        final back = ArenaReader(
          pb.Arena.fromBuffer(writer.arena.writeToBuffer()),
        )[root];
        expect(back, isBigInt);
        expect(back.dartValue, value);
        expect(back.toString(), 'MontyBigInt(1152921504606859321)');
        final negative = _decode([_bigArm(-value)]);
        expect(negative.dartValue, -value);
        expect(negative.toString(), 'MontyBigInt(-1152921504606859321)');
      },
    );

    test('REQ-MontyInt-11: both wire arms decode to one numeric type', () {
      for (final value in [
        BigInt.from(42),
        BigInt.from(-7),
        two53,
        BigInt.one << 60,
        -(BigInt.one << 61),
      ]) {
        final fromInt = _decode([_intArm(value)]);
        final fromBig = _decode([_bigArm(value)]);
        final small = value.abs() <= two53;
        expect(fromInt, small ? isInt : isBigInt);
        expect(fromBig, small ? isInt : isBigInt);
        expect(fromBig.runtimeType, fromInt.runtimeType, reason: '$value');
        expect(fromBig, fromInt, reason: '$value');
        expect(fromBig.dartValue, fromInt.dartValue, reason: '$value');
      }
    });

    test('REQ-MontyBigInt-19: a repeated big integer node is one wrapper', () {
      final nodes = [
        _bigArm(BigInt.one << 70),
        list([0, 0]),
        tuple([0, 0]),
      ];
      final reader = _reader(nodes);
      final [a, b] = (reader[1] as MontyList).items;
      final [_, c] = (reader[2] as MontyTuple).items;
      final root = reader[0];
      expect(a, isBigInt);
      expect(identical(a, b), isTrue);
      expect(identical(a, root), isTrue);
      expect(identical(c, a), isTrue);
    });

    test('REQ-MontyFloat-26: a repeated float node is one wrapper', () {
      final nodes = [
        n(1.5),
        n(double.nan),
        list([0, 0, 1, 1]),
      ];
      final reader = _reader(nodes);
      final [a, b, c, d] = (reader[2] as MontyList).items;
      final root = reader[0];
      expect(identical(a, b), isTrue);
      expect(identical(a, root), isTrue);
      expect(identical(c, d), isTrue);
      expect(identical(a, c), isFalse);
    });
  });

  group('decoded containers are unmodifiable', () {
    test('REQ-MontyBytes-6: decoded bytes', () {
      final bytes = _decode([
        pb.MontyNode(bytes: [1, 2, 3]),
      ]);
      expect(bytes, isA<MontyBytes>());
      final value = (bytes as MontyBytes).value;
      expect(value, [1, 2, 3]);
      expect(() => value[0] = 9, throwsUnsupportedError);
      expect(() => value.add(9), throwsUnsupportedError);
      expect(value, [1, 2, 3]);
    });

    test('REQ-MontyDict-6: decoded pairs', () {
      final decoded =
          _decode([
                n('a'),
                n(1),
                dict([(0, 1)]),
              ])
              as MontyDict;
      expect(decoded.pairs, hasOne);
      expect(
        () => decoded.pairs.add((const MontyInt(1), const MontyInt(2))),
        throwsUnsupportedError,
      );
      expect(decoded.pairs.clear, throwsUnsupportedError);
      expect(
        () => decoded.pairs[0] = (const MontyInt(1), const MontyInt(2)),
        throwsUnsupportedError,
      );
      expect(decoded.pairs, hasOne);
    });

    test('REQ-MontySet-6: decoded items', () {
      final set_ =
          _decode([
                n(1),
                n(2),
                set([0, 1]),
              ])
              as MontySet;
      expect(set_.items, hasLength(2));
      expect(() => set_.items.add(const MontyInt(3)), throwsUnsupportedError);
      expect(set_.items.clear, throwsUnsupportedError);
      expect(() => set_.items[0] = const MontyInt(9), throwsUnsupportedError);
    });

    test('REQ-MontyFrozenSet-6: decoded items', () {
      final frozen_ =
          _decode([
                n(1),
                n(2),
                frozen([0, 1]),
              ])
              as MontyFrozenSet;
      expect(frozen_.items, hasLength(2));
      expect(
        () => frozen_.items.add(const MontyInt(3)),
        throwsUnsupportedError,
      );
      expect(frozen_.items.clear, throwsUnsupportedError);
      expect(
        () => frozen_.items[0] = const MontyInt(9),
        throwsUnsupportedError,
      );
    });

    test('REQ-MontyTuple-5: decoded items, in child order', () {
      final tuple_ =
          _decode([
                n(3),
                n(1),
                n(2),
                tuple([0, 1, 2]),
              ])
              as MontyTuple;
      expect(tuple_.items, [
        const MontyInt(3),
        const MontyInt(1),
        const MontyInt(2),
      ]);
      expect(() => tuple_.items.add(const MontyInt(4)), throwsUnsupportedError);
      expect(tuple_.items.clear, throwsUnsupportedError);
      expect(
        () => tuple_.items[0] = const MontyInt(9),
        throwsUnsupportedError,
      );
      expect(tuple_.items, hasLength(3));
    });

    test('REQ-MontyNamedTuple-5: decoded field names and values', () {
      final named =
          _decode([
                n(1),
                n(2),
                namedTuple('mod.P', ['x', 'y'], [0, 1]),
              ])
              as MontyNamedTuple;
      expect(named.fieldNames, ['x', 'y']);
      expect(named.values, [const MontyInt(1), const MontyInt(2)]);
      expect(() => named.fieldNames.add('z'), throwsUnsupportedError);
      expect(() => named.fieldNames[0] = 'q', throwsUnsupportedError);
      expect(() => named.values.add(const MontyInt(3)), throwsUnsupportedError);
      expect(named.values.clear, throwsUnsupportedError);
      expect(
        () => named.values[0] = const MontyInt(9),
        throwsUnsupportedError,
      );
      expect(named.fieldNames, ['x', 'y']);
    });
  });

  group('named tuple names', () {
    MontyNamedTuple read(String type, List<String> fields) =>
        _decode([
              for (var i = 0; i < fields.length; i++) n(i),
              namedTuple(type, fields, [
                for (var i = 0; i < fields.length; i++) i,
              ]),
            ])
            as MontyNamedTuple;

    test('REQ-MontyNamedTuple-19: only the last segment and fields', () {
      final one = n(1);
      // Any module prefix: it is never checked as an identifier.
      for (final type in [
        'Point',
        'mod.Point',
        'a.b.c.Point',
        'my-mod.Point',
        '1x.Point',
        'a b.Point',
        '..Point',
        'class.Point',
      ]) {
        final decoded = read(type, ['x', 'y']);
        expect(decoded.typeName, type);
        expect(decoded.fieldNames, ['x', 'y']);
      }
      // The segment after the LAST dot is the type's name.
      for (final (type, message) in [
        (
          'mod.1Point',
          "$_notIdentifier'1Point'",
        ),
        (
          'mod.',
          "$_notIdentifier''",
        ),
        (
          'Point.',
          "$_notIdentifier''",
        ),
        (
          'a.b.Po int',
          "$_notIdentifier'Po int'",
        ),
        (
          'mod.class',
          "ValueError: Type names and field names cannot be a keyword: 'class'",
        ),
        (
          'a.b.None',
          "ValueError: Type names and field names cannot be a keyword: 'None'",
        ),
      ]) {
        expect(
          _formatMessage([
            namedTuple(type, ['x'], []),
          ]),
          startsWith('ValueError'),
          reason: type,
        );
        expect(
          _formatMessage([
            one,
            namedTuple(type, ['x'], [0]),
          ]),
          message,
          reason: type,
        );
      }
      // Each field name is checked on its own.
      expect(
        _formatMessage([
          one,
          namedTuple('mod.P', ['x y'], [0]),
        ]),
        "$_notIdentifier'x y'",
      );
      expect(
        _formatMessage([
          one,
          n(2),
          namedTuple('mod.P', ['x', 'def'], [0, 1]),
        ]),
        "ValueError: Type names and field names cannot be a keyword: 'def'",
      );
      expect(
        _formatMessage([
          one,
          namedTuple('mod.P', ['1x'], [0]),
        ]),
        "$_notIdentifier'1x'",
      );
    });
  });

  group('class attributes keep only string keys', () {
    // Node 0 'k', 1 'v', 2 the int key 7, 3 'dropped', 4 repr, 5 cycle, 6
    // function; only the pair keyed by the `str` node 0 is kept, in the
    // class and the instance.
    List<pb.MontyNode> nodes() => [
      n('k'),
      n('v'),
      n(7),
      n('dropped'),
      pb.MontyNode(repr: 'r'),
      pb.MontyNode(cycle: 'c'),
      pb.MontyNode(function: pb.Function_(name: 'f')),
      classType(
        'C',
        id: uuid(1),
        attrs: pairs([(0, 1), (2, 3), (4, 3), (5, 3), (6, 3)]),
      ),
      instance(
        7,
        id: uuid(2),
        attrs: pairs([(0, 1), (2, 3), (4, 3), (5, 3), (6, 3)]),
      ),
    ];

    test('REQ-MontyClassProxy-6: instance and class attributes', () {
      final decoded = _decode(nodes()) as MontyClassProxy;
      expect(decoded.attrs.keys, ['k']);
      expect(decoded.attrs['k'], const MontyString('v'));
      final classAttrs = decoded.classType.attrs;
      expect(classAttrs.keys, ['k']);
      expect(classAttrs['k'], const MontyString('v'));
    });

    test('REQ-MontyClassTypeProxy-11: class attributes', () {
      final decoded = _decode(nodes(), 7) as MontyClassTypeProxy;
      expect(decoded.attrs.keys, ['k']);
      expect(decoded.attrs['k'], const MontyString('v'));
      // Only non-string keys: nothing is kept.
      final none =
          _decode([
                n(1),
                n(2),
                classType('C', id: uuid(1), attrs: pairs([(0, 1)])),
              ])
              as MontyClassTypeProxy;
      expect(none.attrs, isEmpty);
    });
  });

  group('field presence and identity', () {
    test('REQ-MontyComplex-24: both parts missing report real', () {
      final real = contains('Complex.real');
      final imag = contains('Complex.imag');
      final both = _formatMessage([pb.MontyNode(complex: pb.Complex())]);
      expect(both, real);
      expect(both, isNot(imag));
      expect(_formatMessage([complexNode(real: 1)]), imag);
      expect(_formatMessage([complexNode(imag: 1)]), real);
    });

    test('REQ-MontyEllipsis-9: the canonical const instance', () {
      final decoded = _decode([pb.MontyNode(ellipsis: pb.Unit())]);
      expect(decoded, const MontyEllipsis());
      expect(identical(decoded, const MontyEllipsis()), isTrue);
    });

    test('REQ-MontyTime-6: the reader enforces the same field ranges', () {
      pb.MontyNode at({
        int hour = 3,
        int minute = 4,
        int second = 5,
        int microsecond = 6,
        int? offset,
        int fold = 0,
      }) => time(
        hour: hour,
        minute: minute,
        second: second,
        microsecond: microsecond,
        offset: offset,
        fold: fold,
      );
      final top =
          _decode([
                at(
                  hour: 23,
                  minute: 59,
                  second: 59,
                  microsecond: 999999,
                  offset: 86399,
                  fold: 1,
                ),
              ])
              as MontyTime;
      expect(
        [top.hour, top.minute, top.second, top.microsecond, top.offsetSeconds],
        [23, 59, 59, 999999, 86399],
      );
      expect(top.fold, 1);
      expect(
        (_decode([at(offset: -86399)]) as MontyTime).offsetSeconds,
        -86399,
      );
      for (final bad in [
        at(hour: 24),
        at(minute: 60),
        at(second: 60),
        at(microsecond: 1000000),
        at(fold: 2),
        at(offset: 86400),
        at(offset: -86400),
      ]) {
        expect(() => _decode([bad]), throwsFormatException);
      }
    });

    test(
      'REQ-MontyTimeZone-10: offset and name, empty differs from absent',
      () {
        final named = _decode([zone(-3600, 'CET')]) as MontyTimeZone;
        expect(named.offsetSeconds, -3600);
        expect(named.name, 'CET');
        final empty = _decode([zone(60, '')]) as MontyTimeZone;
        expect(empty.offsetSeconds, 60);
        expect(empty.name, '');
        final absent = _decode([zone(60)]) as MontyTimeZone;
        expect(absent.offsetSeconds, 60);
        expect(absent.name, isNull);
      },
    );

    test('REQ-MontyDateTime-13: the decoder keeps empty and absent names', () {
      final empty = _decode([datetime(offset: 60, name: '')]) as MontyDateTime;
      expect(empty.timezoneName, '');
      expect(empty.offsetSeconds, 60);
      final absent = _decode([datetime(offset: 60)]) as MontyDateTime;
      expect(absent.timezoneName, isNull);
      final naive = _decode([datetime()]) as MontyDateTime;
      expect(naive.offsetSeconds, isNull);
      expect(naive.timezoneName, isNull);
      expect(
        [naive.year, naive.month, naive.day, naive.hour, naive.minute],
        [2026, 1, 2, 3, 4],
      );
      expect([naive.second, naive.microsecond], [5, 6]);
    });

    test(
      'REQ-MontyString-13: repr, cycle and function nodes decode to str',
      () {
        for (final (node, text) in [
          (pb.MontyNode(repr: '<obj>'), '<obj>'),
          (pb.MontyNode(cycle: '[...]'), '[...]'),
          (pb.MontyNode(function: pb.Function_(name: 'f')), 'f'),
        ]) {
          final decoded = _decode([node]);
          expect(decoded.runtimeType, MontyString);
          expect(decoded, MontyString(text));
        }
      },
    );
  });
}
