// The arena reader against every node kind upstream emits, and against
// upstream's validation: each fixture in _arena_fixtures.dart is accepted or
// rejected exactly as upstream's decoder does, with its message. Pure Dart,
// so the unit and unit_web steps run it on the VM, dart2js and dart2wasm.
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show HostClass, montyStdTypeProxy;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_keys.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_arena_fixtures.dart';

/// The arena after a wire round trip, so presence survives as it would.
ArenaReader _reader(List<pb.MontyNode> nodes, {HostObjectLookup? hosts}) =>
    ArenaReader(
      pb.Arena.fromBuffer(
        pb.Arena(nodeCount: nodes.length, nodes: nodes).writeToBuffer(),
      ),
      hosts: hosts,
    );

MontyValue _decode(List<pb.MontyNode> nodes, [int? root]) =>
    _reader(nodes)[root ?? nodes.length - 1];

Matcher _formatError(String message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

/// One node per value, each its own node even when two values are equal.
List<pb.MontyNode> ns(List<Object?> values) => [for (final v in values) n(v)];

/// A node from a compact spec, so a case can name two equal nodes without
/// repeating a constructor call.
pb.MontyNode _spec(Object? spec) => switch (spec) {
  #ellipsis => pb.MontyNode(ellipsis: pb.Unit()),
  #notImplemented => pb.MontyNode(notImplemented: pb.Unit()),
  #date => date(2026, 1, 2),
  #datetime => datetime(hour: 0, minute: 0, second: 0, microsecond: 0),
  #delta => delta(1, 2, 3),
  #file => file('r'),
  final String text when text.startsWith('@') => _specOf(text.split(' ')),
  _ => n(spec),
};

/// `@kind arg...`: a node of a kind [n] does not build.
pb.MontyNode _specOf(List<String> words) => switch (words) {
  ['@big', final bits] => bigIntNode(BigInt.one << int.parse(bits)),
  ['@cycle', final text] => pb.MontyNode(cycle: text),
  ['@path', final text] => pb.MontyNode(path: text),
  ['@zone', ...final name] => zone(0, name.firstOrNull),
  ['@complex', final real, final imag] => complexNode(
    real: double.parse(real),
    imag: double.parse(imag),
  ),
  _ => throw ArgumentError.value(words),
};

Matcher _setOfLength(int length) =>
    isA<MontySet>().having((s) => s.items, 'items', hasLength(length));

pb.MontyNode _function(String name) =>
    pb.MontyNode(function: pb.Function_(name: name));

void main() {
  group('upstream validation, fixture by fixture', () {
    for (final f in arenaFixtures) {
      test(f.name, () {
        MontyValue read() => _reader(f.nodes)[f.rootIndex];
        if (f.error case final error?) {
          expect(read, _formatError(error));
        } else {
          // Accepted by every check; a staged kind may still have no class
          // yet (see the staged-kind tests).
          expect(read, anyOf(returnsNormally, throwsUnsupportedError));
        }
      });
    }

    test('a failure is thrown again on every read', () {
      final reader = _reader([date(2026, 2, 30), n(1)]);
      expect(() => reader[1], throwsFormatException);
      expect(() => reader[0], throwsFormatException);
    });

    test('a bad root fails only its own read', () {
      final reader = _reader([n(1)]);
      expect(() => reader[-1], throwsFormatException);
      expect(reader[0], const MontyInt(1));
    });
  });

  group('every kind decodes to the class of the same meaning', () {
    test('singletons', () {
      expect(
        _decode([pb.MontyNode(ellipsis: pb.Unit())]),
        const MontyEllipsis(),
      );
      expect(
        _decode([pb.MontyNode(notImplemented: pb.Unit())]),
        const MontyNotImplemented(),
      );
    });

    test('dates, times, deltas and zones', () {
      expect(
        _decode([date(2000, 2, 29)]),
        const MontyDate(year: 2000, month: 2, day: 29),
      );
      expect(
        _decode([datetime(offset: 3600, name: 'CET')]),
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 2,
          hour: 3,
          minute: 4,
          second: 5,
          microsecond: 6,
          offsetSeconds: 3600,
          timezoneName: 'CET',
        ),
      );
      expect(
        _decode([datetime()]),
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 2,
          hour: 3,
          minute: 4,
          second: 5,
          microsecond: 6,
        ),
      );
      expect(
        _decode([time(offset: 0, name: '', fold: 1)]),
        const MontyTime(
          hour: 3,
          minute: 4,
          second: 5,
          microsecond: 6,
          offsetSeconds: 0,
          timezoneName: '',
          fold: 1,
        ),
      );
      expect(
        _decode([delta(-1, 86399, 999999)]),
        const MontyTimeDelta(days: -1, seconds: 86399, microseconds: 999999),
      );
      expect(
        _decode([zone(-3600, 'X')]),
        const MontyTimeZone(offsetSeconds: -3600, name: 'X'),
      );
      expect(_decode([zone(0)]), const MontyTimeZone(offsetSeconds: 0));
    });

    test('exceptions as upstream builds them', () {
      expect(
        _decode([exception('KeyError', 'k')]),
        MontyExceptionValue('KeyError', 'k'),
      );
      // No argument is an empty message: exc_monty_to_py's unwrap_or_default.
      expect(
        _decode([exception('ValueError')]),
        MontyExceptionValue('ValueError', ''),
      );
      // A value node carries no payload, and these three need one.
      for (final type in [
        'UnicodeDecodeError',
        'UnicodeEncodeError',
        'json.JSONDecodeError',
      ]) {
        expect(
          _decode([exception(type, 'm')]),
          MontyExceptionValue('ValueError', 'm'),
          reason: type,
        );
      }
    });

    test('builtin types and functions are opaque; `type` is the type', () {
      expect(
        _decode([builtinType('ValueError')]),
        montyStdTypeProxy('type', 'ValueError'),
      );
      expect(
        _decode([pb.MontyNode(builtinFunction: 'len')]),
        montyStdTypeProxy('function', 'len'),
      );
      expect(
        _decode([pb.MontyNode(builtinFunction: 'type')]),
        montyStdTypeProxy('type', 'type'),
      );
    });

    test('repr, cycle and an output function are their text', () {
      expect(_decode([pb.MontyNode(repr: '<o>')]), const MontyString('<o>'));
      expect(
        _decode([
          pb.MontyNode(cycle: '[...]'),
          list([0]),
        ]),
        const MontyList([MontyString('[...]')]),
      );
      expect(_decode([_function('f')]), const MontyString('f'));
    });

    test('a path is normalized as PurePosixPath', () {
      const cases = {
        '': '.',
        '.': '.',
        'a//./b/': 'a/b',
        './a': 'a',
        '//a': '//a',
        '///a': '/a',
        '/./a/..': '/a/..',
        '../x': '../x',
        '/': '/',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
          _decode([pb.MontyNode(path: key)]),
          MontyPath(value),
          reason: key,
        );
      }
    });

    test('a file handle with its canonical mode', () {
      expect(
        _decode([file('rt', path: '/x')]),
        MontyFileHandle('/x', 'r'),
      );
      expect(
        _decode([file('br')]),
        MontyFileHandle('/f', 'rb'),
      );
    });

    test('a named tuple', () {
      expect(
        _decode([
          n(1),
          namedTuple('os.stat_result', ['st_mode'], [0]),
        ]),
        const MontyNamedTuple(
          typeName: 'os.stat_result',
          fieldNames: ['st_mode'],
          values: [MontyInt(1)],
        ),
      );
    });

    test('class instances share their class node', () {
      final v =
          _decode([
                n('k'),
                n(1),
                classType(
                  'P',
                  origin: 3,
                  id: uuid(0xab),
                  dataclass: true,
                  attrs: pairs([(0, 1)]),
                ),
                n('x'),
                n(2),
                instance(2, id: uuid(1), attrs: pairs([(3, 4)])),
                instance(2, id: uuid(2), attrs: pairs([])),
                list([5, 6]),
              ])
              as MontyList;
      final a = itemAt(v.items, 0) as MontyClassProxy;
      final b = itemAt(v.items, 1) as MontyClassProxy;
      expect(identical(a.classType, b.classType), isTrue);
      expect(a.classType.name, 'P');
      expect(a.classType.id, 'abababab-abab-abab-abab-abababababab');
      expect(a.classType.hostDefined, isTrue);
      expect(a.classType.isDataclass, isTrue);
      expect(a.classType.attrs, {'k': const MontyInt(1)});
      expect(a.instanceId, '01010101-0101-0101-0101-010101010101');
      expect(a.attrs, {'x': const MontyInt(2)});
      expect(b.attrs, isEmpty);
    });

    test('attributes keep only str keys; a repeated name takes the last', () {
      final v =
          _decode([
                classType('C', id: uuid(1)),
                n('a'),
                n(1),
                n(2),
                _function('a'),
                pb.MontyNode(repr: 'a'),
                n(3),
                instance(
                  0,
                  id: uuid(2),
                  attrs: pairs([(1, 2), (2, 2), (4, 3), (5, 3), (1, 6)]),
                ),
              ])
              as MontyClassProxy;
      // The int key, the function and the repr are skipped, though the
      // last two decode to the text 'a'.
      expect(v.attrs, {'a': const MontyInt(3)});
    });
  });

  group('dicts and sets are built as Python builds them', () {
    MontyDict dictOf(List<pb.MontyNode> nodes) => _decode(nodes) as MontyDict;

    test('numeric aliases collapse: first key, last value, first place', () {
      final d = dictOf([
        n('z'), n(0), //
        n(1), n('a'),
        n(true), n('b'),
        floatNode(1), n('c'),
        complexNode(real: 1, imag: 0), n('d'),
        dict([(0, 1), (2, 3), (4, 5), (6, 7), (8, 9)]),
      ]);
      expect(d.pairs, [
        (const MontyString('z'), const MontyInt(0)),
        (const MontyInt(1), const MontyString('d')),
      ]);
    });

    test('every hashable kind keys by Python equality', () {
      // Pairs of node specs (see _spec), equal as Python keys or not.
      const cases = <(Object?, Object?, bool)>[
        (null, null, true),
        (#ellipsis, #ellipsis, true),
        (#notImplemented, #notImplemented, true),
        ('@big 70', '@big 70', true),
        (1048576, '@big 20', true),
        ('@cycle [...]', '[...]', true),
        ('@path a//b', '@path a/b/', true),
        ('@path a', 'a', false),
        (#date, #date, true),
        (#date, #datetime, false),
        (#delta, #delta, true),
        (1.5, '@complex 1.5 0', true),
        (1.5, 1.25, false),
        ('@complex 1 2', '@complex 1 2', true),
        ('@complex 1 2', '@complex 2 1', false),
        (double.infinity, double.infinity, true),
        (double.infinity, double.negativeInfinity, false),
        (-0.0, 0, true),
        ('@complex NaN 1', '@complex NaN 1', false),
        ('@complex 1 NaN', '@complex 1 NaN', false),
        (#file, #file, false),
        ('@zone A', '@zone', true),
      ];
      final nodes = [
        for (final (a, b, _) in cases) ...[_spec(a), _spec(b)],
      ];
      final keys = PythonKeys(nodes, {});
      for (final (i, (a, b, equal)) in cases.indexed) {
        final same = keys.keyOf(i * 2) == keys.keyOf(i * 2 + 1);
        expect(same, equal, reason: '$a and $b');
      }
    });

    test('distinct NaNs are distinct keys; one shared NaN is one key', () {
      const nan = double.nan;
      final distinct = dictOf([
        ...ns([nan, nan, 1]),
        dict([(0, 2), (1, 2)]),
      ]);
      expect(distinct.pairs, hasLength(2));
      final shared = dictOf([
        ...ns([nan, 1, 2]),
        dict([(0, 1), (0, 2)]),
      ]);
      expect(shared.pairs, hasLength(1));
      expect(shared.pairs.firstOrNull?.$2, const MontyInt(2));
      // A tuple holding the same NaN twice is equal to itself.
      expect(
        _decode([
          ...ns([nan]),
          tuple([0]),
          tuple([0]),
          set([1, 2]),
        ]),
        _setOfLength(1),
      );
      expect(
        _decode([
          ...ns([nan, nan]),
          tuple([0]),
          tuple([1]),
          set([2, 3]),
        ]),
        _setOfLength(2),
      );
    });

    test('exceptions are keys by identity', () {
      // Two equal exceptions, then a set of both, and a set of one twice.
      final arena = [
        for (var i = 0; i < 2; i++) exception('KeyError', 'k'),
        set([0, 1]),
        set([0, 0]),
      ];
      final reader = _reader(arena);
      expect(reader[2], _setOfLength(2));
      expect(reader[3], _setOfLength(1));
    });

    test('a function or repr equal to a string collapses with it', () {
      final d = dictOf([
        _function('f'),
        n(1),
        n('f'),
        n(2),
        pb.MontyNode(repr: 'range(0, 3)'),
        n(3),
        n('range(0, 3)'),
        n(4),
        dict([(0, 1), (2, 3), (4, 5), (6, 7)]),
      ]);
      expect(d.pairs, [
        (const MontyString('f'), const MontyInt(2)),
        (const MontyString('range(0, 3)'), const MontyInt(4)),
      ]);
    });

    test('equivalent instants, wall clocks and offsets collapse', () {
      final d = dictOf([
        datetime(hour: 12, minute: 0, second: 0, microsecond: 0, offset: 3600),
        n(1),
        datetime(
          hour: 11,
          minute: 0,
          second: 0,
          microsecond: 0,
          offset: 0,
          name: 'UTC',
        ),
        n(2),
        datetime(hour: 11, minute: 0, second: 0, microsecond: 0),
        n(3),
        time(hour: 12, minute: 0, second: 0, microsecond: 0, offset: 3600),
        time(
          hour: 11,
          minute: 0,
          second: 0,
          microsecond: 0,
          offset: 0,
          fold: 1,
        ),
        time(hour: 0, minute: 30, second: 0, microsecond: 0, offset: 3600),
        time(hour: 23, minute: 30, second: 0, microsecond: 0, offset: 0),
        zone(3600, 'A'),
        zone(3600, 'B'),
        dict([
          (0, 1),
          (2, 3),
          (4, 5),
          (6, 1),
          (7, 3),
          (8, 1),
          (9, 1),
          (10, 1),
          (11, 5),
        ]),
      ]);
      // 12:00+01:00 and 11:00 UTC are one instant (first key, value 2);
      // the naive datetime is neither; the two aware times are one wall
      // clock (value 2), 00:30+01:00 and 23:30+00:00 are not (no wrapping);
      // the two zones compare by offset alone (value 3).
      expect(d.pairs.map((p) => p.$2), const [
        MontyInt(2),
        MontyInt(3),
        MontyInt(2),
        MontyInt(1),
        MontyInt(1),
        MontyInt(3),
      ]);
    });

    test('named tuples key as tuples; frozensets as sets', () {
      final s =
          _decode([
                n(1),
                floatNode(1),
                tuple([0]),
                namedTuple('P', ['x'], [1]),
                frozen([0, 1]),
                frozen([1]),
                set([2, 3, 4, 5]),
              ])
              as MontySet;
      expect(s.items, hasLength(2));
      expect(s.items.firstOrNull, const MontyTuple([MontyInt(1)]));
    });

    test('duplicate set members keep the first, in order', () {
      // floatNode, not n(2.0): on dart2js 2.0 is an int and n() would
      // build an int node.
      final members = [
        ...ns([2, 1]),
        floatNode(2),
      ];
      expect(
        _decode([
          ...members,
          set([0, 1, 2]),
        ]),
        const MontySet([MontyInt(2), MontyInt(1)]),
      );
      expect(
        _decode([
          ...members,
          frozen([0, 1, 2]),
        ]),
        const MontyFrozenSet([MontyInt(2), MontyInt(1)]),
      );
    });

    test('bytes, str and builtins are different keys', () {
      expect(
        _decode([
          pb.MontyNode(bytes: [97]),
          n('a'),
          builtinType('type'),
          pb.MontyNode(builtinFunction: 'type'),
          builtinType('int'),
          set([0, 1, 2, 3, 4]),
        ]),
        isA<MontySet>().having((s) => s.items, 'items', hasLength(4)),
      );
    });
  });

  group('the kinds the cutover adds', () {
    test('a complex, alone or inside a container', () {
      final reader = _reader([
        complexNode(real: 1, imag: 2),
        list([0]),
        complexNode(real: -0, imag: double.nan),
      ]);
      expect(reader[0], const MontyComplex(1, 2));
      expect(
        identical(onlyItem((reader[1] as MontyList).items), reader[0]),
        isTrue,
      );
      final c = reader[2] as MontyComplex;
      expect(c.real.isNegative && c.real == 0, isTrue);
      expect(c.imag.isNaN, isTrue);
    });

    test('a class type as a value is a MontyClassTypeProxy', () {
      final reader = _reader([
        n('k'),
        n(7),
        classType('C', id: uuid(1), attrs: pairs([(0, 1)])),
        instance(2, id: uuid(2), attrs: pairs([])),
        instance(2, id: uuid(3), attrs: pairs([])),
      ]);
      final type = reader[2] as MontyClassTypeProxy;
      expect(type.name, 'C');
      expect(type.attrs, {'k': const MontyInt(7)});
      final third = (reader[3] as MontyClassProxy).classType;
      expect(identical(third, type), isTrue);
      expect(
        identical(third, (reader[4] as MontyClassProxy).classType),
        isTrue,
      );
    });

    test('a file position up to 2^64-1, exactly, on every compiler', () {
      MontyValue at(BigInt position) => _decode([
        pb.MontyNode(
          fileHandle: pb.FileHandle(
            path: '/f',
            mode: 'r',
            position: Int64.parseHex(position.toRadixString(16)),
          ),
        ),
      ]);
      for (final p in [
        BigInt.one << 53,
        (BigInt.one << 53) + BigInt.one,
        BigInt.one << 63,
        (BigInt.one << 64) - BigInt.one,
      ]) {
        expect((at(p) as MontyFileHandle).position, p);
      }
    });
  });

  group('review regressions', () {
    test('an overwritten attribute is not decoded into its instance', () {
      final v =
          _decode([
                n('x'),
                complexNode(real: 0, imag: 1),
                n(1),
                classType('C', id: uuid(1), attrs: pairs([(0, 1), (0, 2)])),
                instance(3, id: uuid(2), attrs: pairs([(0, 1), (0, 2)])),
              ])
              as MontyClassProxy;
      expect(v.attrs, {'x': const MontyInt(1)});
      expect(v.classType.attrs, {'x': const MontyInt(1)});
    });

    test('a wide frozenset referenced 30,000 times is keyed once', () {
      const width = 30000;
      final nodes = [
        for (var i = 0; i < width; i++) n(i),
        frozen([for (var i = 0; i < width; i++) i]),
        set(List.filled(width, width)),
      ];
      final watch = Stopwatch()..start();
      expect(_decode(nodes), _setOfLength(1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a 100,000-wide tuple as a key is walked once', () {
      const width = 100000;
      final nodes = [
        for (var i = 0; i < width; i++) n(i),
        tuple([for (var i = 0; i < width; i++) i]),
        set([width]),
      ];
      final watch = Stopwatch()..start();
      expect(_decode(nodes), _setOfLength(1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('host objects', () {
    const registered = MontyString('registered');

    test('registered instances and classes replace their proxies', () {
      final asked = <String>[];
      final reader = _reader(
        [
          classType('C', id: uuid(1)),
          instance(0, id: uuid(2), attrs: pairs([])),
          instance(0, id: uuid(3), attrs: pairs([])),
          list([0, 1, 2]),
        ],
        hosts: (
          classType: (id) {
            asked.add('class $id');

            return registered;
          },
          instance: (id) {
            asked.add('instance $id');

            return id.startsWith('02') ? registered : null;
          },
        ),
      );
      final items = (reader[3] as MontyList).items;
      expect(identical(itemAt(items, 0), registered), isTrue);
      expect(identical(itemAt(items, 1), registered), isTrue);
      // Not registered, though its class is: a proxy.
      expect(itemAt(items, 2), isA<MontyClassProxy>());
      expect(asked, [
        'class 01010101-0101-0101-0101-010101010101',
        'instance 02020202-0202-0202-0202-020202020202',
        'instance 03030303-0303-0303-0303-030303030303',
      ]);
    });

    test('every class and instance node is asked, reachable or not', () {
      final asked = <String>[];
      final reader = _reader(
        [
          classType('C', id: uuid(1)),
          instance(0, id: uuid(2), attrs: pairs([])),
          n(1),
        ],
        hosts: (
          classType: (id) {
            asked.add(id);

            return null;
          },
          instance: (id) {
            asked.add(id);

            return null;
          },
        ),
      );
      expect(reader[2], const MontyInt(1));
      expect(asked, hasLength(2));
    });

    test('a registered object is a key by its own == and hashCode', () {
      // Upstream decodes the node to the original object and inserts it
      // with Python's own hash and equality (decode.rs:106-120, 144-165):
      // equal objects collapse, the first key keeping the last value.
      // Built at run time, so the two equal keys are distinct objects.
      const keyClass = HostClass<_Key>('C');
      final type = ClassType(keyClass);
      final [first, same, other] = [
        for (final n in [1, 1, 2]) ClassInstance(_Key(n), classType: type),
      ];
      final objects = {'02': first, '03': same, '04': other};
      final reader = _reader(
        [
          classType('C', id: uuid(1)),
          for (final b in [2, 3, 4]) instance(0, id: uuid(b), attrs: pairs([])),
          set([1, 2, 3]),
          for (final v in [1, 2, 3]) n(v),
          dict([(1, 5), (2, 6), (3, 7)]),
        ],
        hosts: (
          classType: (_) => null,
          instance: (id) => objects[id.substring(0, 2)],
        ),
      );
      final members = (reader[4] as MontySet).items;
      expect([for (final m in members) m], [first, other]);
      final entries = (reader[8] as MontyDict).pairs;
      expect(
        [for (final (k, v) in entries) (k, v)],
        [(first, const MontyInt(2)), (other, const MontyInt(3))],
      );
      expect(identical(firstItem(entries).$1, first), isTrue);
    });

    test('registered objects equal only to themselves stay apart', () {
      final type = ClassType(const HostClass('C'));
      final a = ClassInstance(Object(), classType: type);
      final b = ClassInstance(Object(), classType: type);
      final reader = _reader(
        [
          classType('C', id: uuid(1)),
          for (final x in [2, 2, 3]) instance(0, id: uuid(x), attrs: pairs([])),
          set([1, 2, 3]),
        ],
        hosts: (
          classType: (_) => null,
          instance: (id) => id.startsWith('02') ? a : b,
        ),
      );
      final members = (reader[4] as MontySet).items;
      expect([for (final m in members) m], [a, b]);
    });
  });

  group('cost', () {
    test('a 10,000-level shared tuple DAG as a key decodes in linear time', () {
      // x = (x, x) ten thousand times: 2^10000 paths.
      final nodes = [
        n(0),
        for (var i = 0; i < 10000; i++) tuple([i, i]),
        n(1),
        dict([(10000, 10001)]),
      ];
      final watch = Stopwatch()..start();
      expect(_decode(nodes), isA<MontyDict>());
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a 100,000-level nested tuple as a set member', () {
      final nodes = [
        n(0),
        for (var i = 0; i < 100000; i++) tuple([i]),
        set([100000, 100000]),
      ];
      final watch = Stopwatch()..start();
      expect((_decode(nodes) as MontySet).items, hasLength(1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a 1 MiB payload shared 10,000 times keys once', () {
      final big = pb.MontyNode(bytes: Uint8List(1 << 20));
      final nodes = [
        big,
        for (var i = 0; i < 10000; i++) tuple([0]),
        set([for (var i = 1; i <= 10000; i++) i]),
      ];
      final watch = Stopwatch()..start();
      expect((_decode(nodes) as MontySet).items, hasLength(1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}

/// A host object equal to any other with the same [n].
@immutable
final class _Key {
  const _Key(this.n);

  final int n;

  @override
  bool operator ==(Object other) => other is _Key && other.n == n;

  @override
  int get hashCode => n.hashCode;
}
