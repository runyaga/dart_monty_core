// Tests for the arena writer: wire invariants of the outbound encoder (fresh
// leaves, shared containers, child order, hashability refusals, time ranges).
// Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

/// The arena [values] are written into, one `add` each, with the roots.
(List<pb.MontyNode>, List<int>) _write(List<MontyValue> values) {
  final writer = ArenaWriter();
  final roots = [for (final v in values) writer.add(v)];

  return (writer.arena.nodes, roots);
}

/// [value] written, sent over the wire and read back.
MontyValue _roundTrip(MontyValue value) {
  final writer = ArenaWriter();
  final root = writer.add(value);

  return ArenaReader(pb.Arena.fromBuffer(writer.arena.writeToBuffer()))[root];
}

/// The message of the [ArgumentError] writing [value] raises.
String _refusal(MontyValue value) {
  Object? caught;
  try {
    ArenaWriter().add(value);
  } on Object catch (e) {
    caught = e;
  }

  return switch (caught) {
    ArgumentError(:final message) => '$message',
    _ => fail('writing $value was not refused'),
  };
}

/// The last node of [nodes].
pb.MontyNode _lastNode(List<pb.MontyNode> nodes) =>
    itemAt(nodes, nodes.length - 1);

/// Upstream's refusal of a list, a dict or a set as a key or member.
final Matcher refusesList = contains("TypeError: unhashable type: 'list'");
final Matcher refusesDict = contains("TypeError: unhashable type: 'dict'");
final Matcher refusesSet = contains("TypeError: unhashable type: 'set'");

/// The integer in an `int` node.
int _int(pb.MontyNode node) => intOfNode(node).toInt();

const _unhashableList = MontyList([]);
const _unhashableDict = MontyDict([]);
const _unhashableSet = MontySet([]);

MontyNamedTuple _named(List<MontyValue> values) => MontyNamedTuple(
  typeName: 'P',
  fieldNames: [for (var i = 0; i < values.length; i++) 'f$i'],
  values: values,
);

MontyTime _time({
  int hour = 1,
  int minute = 2,
  int second = 3,
  int microsecond = 4,
  int? offset,
  String? name,
  int fold = 0,
}) => MontyTime(
  hour: hour,
  minute: minute,
  second: second,
  microsecond: microsecond,
  offsetSeconds: offset,
  timezoneName: name,
  fold: fold,
);

void main() {
  group('a leaf is a fresh node at each reference', () {
    // The same Dart object, referenced twice in one list and added twice.
    void fresh(MontyValue leaf, pb.MontyNode_Kind kind) {
      final (nodes, _) = _write([
        MontyList([leaf, leaf]),
      ]);
      expect(nodes.map((n) => n.whichKind()), [
        kind,
        kind,
        pb.MontyNode_Kind.list,
      ]);
      expect(_lastNode(nodes).list.items, [0, 1]);

      final writer = ArenaWriter();
      final first = writer.add(leaf);
      final second = writer.add(leaf);
      expect(second, isNot(first));
      expect(writer.arena.nodes, hasLength(2));
    }

    test('a MontyBigInt', () {
      fresh(MontyBigInt(BigInt.one << 70), pb.MontyNode_Kind.bigint);
    });

    test('a MontyBytes', () {
      fresh(const MontyBytes([1, 2]), pb.MontyNode_Kind.bytes);
    });

    test('a MontyEllipsis, equality unchanged', () {
      fresh(const MontyEllipsis(), pb.MontyNode_Kind.ellipsis);
      expect(const MontyEllipsis(), const MontyEllipsis());
    });

    test('a MontyFloat', () {
      fresh(const MontyFloat(1.5), pb.MontyNode_Kind.float);
    });

    test('a MontyFileHandle, across containers', () {
      final handle = MontyFileHandle('/f', 'r');
      fresh(handle, pb.MontyNode_Kind.fileHandle);
      final (nodes, roots) = _write([
        MontyList([handle]),
        MontyTuple([handle]),
        MontyList([handle, handle]),
      ]);
      final handles = nodes
          .where((n) => n.whichKind() == pb.MontyNode_Kind.fileHandle)
          .length;
      expect(handles, 4);
      expect(roots, hasLength(3));
    });
  });

  group('child order', () {
    final ints = [
      for (final i in [10, 20, 30]) MontyInt(i),
    ];

    List<int> values(pb.Arena arena, Iterable<int> refs) => [
      for (final r in refs) _int(itemAt(arena.nodes, r)),
    ];

    test('a list node holds its items in sequence', () {
      final writer = ArenaWriter();
      final root = writer.add(MontyList(ints));
      final node = itemAt(writer.arena.nodes, root);
      expect(node.whichKind(), pb.MontyNode_Kind.list);
      expect(values(writer.arena, node.list.items), [10, 20, 30]);
    });

    test('a tuple node holds its items in order', () {
      final writer = ArenaWriter();
      final root = writer.add(MontyTuple(ints));
      final node = itemAt(writer.arena.nodes, root);
      expect(node.whichKind(), pb.MontyNode_Kind.tuple);
      expect(values(writer.arena, node.tuple.items), [10, 20, 30]);
    });

    test('a dict node holds key and value in pairs order', () {
      final writer = ArenaWriter();
      final root = writer.add(
        const MontyDict([
          (MontyString('a'), MontyInt(1)),
          (MontyString('b'), MontyInt(2)),
          (MontyString('c'), MontyInt(3)),
        ]),
      );
      final node = itemAt(writer.arena.nodes, root);
      expect(node.whichKind(), pb.MontyNode_Kind.dict);
      final pairs = node.dict.pairs;
      final nodes = writer.arena.nodes;
      expect(
        [for (final p in pairs) itemAt(nodes, p.key).str],
        ['a', 'b', 'c'],
      );
      expect(
        [for (final p in pairs) _int(itemAt(nodes, p.value))],
        [1, 2, 3],
      );
    });
  });

  group('a container is one node per Dart object', () {
    test('a repeated named tuple is shared', () {
      final shared = _named([const MontyInt(7)]);
      final (nodes, _) = _write([
        MontyList([shared, shared]),
      ]);
      // The int, the named tuple once, the list.
      expect(nodes, hasLength(3));
      expect(itemAt(nodes, 1).whichKind(), pb.MontyNode_Kind.namedTuple);
      expect(_lastNode(nodes).list.items, [1, 1]);

      // An equal but distinct object is its own node.
      final (apart, _) = _write([
        MontyList([
          _named([const MontyInt(7)]),
          _named([const MontyInt(7)]),
        ]),
      ]);
      expect(apart, hasLength(5));
      expect(_lastNode(apart).list.items, [1, 3]);
    });
  });

  group('a key or member Python cannot hash is refused, first one named', () {
    String keyIn(MontyValue member) =>
        _refusal(MontyDict([(member, const MontyInt(1))]));

    test('tuple, named tuple and frozenset keys', () {
      for (final (make, name)
          in <(MontyValue Function(List<MontyValue>), String)>[
            (MontyTuple.new, 'tuple'),
            (_named, 'named tuple'),
            (MontyFrozenSet.new, 'frozenset'),
          ]) {
        expect(
          keyIn(make([const MontyInt(1), _unhashableList, _unhashableDict])),
          refusesList,
          reason: name,
        );
        expect(
          keyIn(make([_unhashableDict, _unhashableList])),
          refusesDict,
          reason: name,
        );
      }
      // Recursively: the unhashable member is inside a nested tuple.
      expect(
        keyIn(
          const MontyTuple([
            MontyTuple([_unhashableSet]),
          ]),
        ),
        refusesSet,
      );
      // A hashable key is written.
      expect(
        () => ArenaWriter().add(
          const MontyDict([
            (
              MontyTuple([MontyInt(1), MontyString('a')]),
              _unhashableList,
            ),
          ]),
        ),
        returnsNormally,
      );
    });

    test('a frozenset key needs hashable members', () {
      const inner = MontyTuple([MontyInt(1), _unhashableList]);
      expect(
        keyIn(const MontyFrozenSet([inner])),
        refusesList,
      );
      expect(
        keyIn(
          const MontyFrozenSet([
            MontyFrozenSet([_unhashableDict]),
          ]),
        ),
        refusesDict,
      );
      expect(
        () => ArenaWriter().add(
          const MontyDict([
            (
              MontyFrozenSet([
                MontyTuple([MontyInt(1)]),
              ]),
              MontyInt(2),
            ),
          ]),
        ),
        returnsNormally,
      );
    });

    test('the message names the first offender', () {
      expect(
        _refusal(const MontyFrozenSet([_unhashableDict, _unhashableList])),
        refusesDict,
      );
      expect(
        _refusal(const MontyFrozenSet([_unhashableList, _unhashableDict])),
        refusesList,
      );
      expect(
        _refusal(const MontyFrozenSet([MontyInt(1), _unhashableSet])),
        refusesSet,
      );
    });

    test('set elements, recursively, in stored order', () {
      for (final make in <MontyValue Function(List<MontyValue>)>[
        MontyTuple.new,
        _named,
        MontyFrozenSet.new,
      ]) {
        expect(
          _refusal(
            MontySet([
              make([const MontyInt(1), _unhashableList]),
              make([_unhashableDict]),
            ]),
          ),
          refusesList,
        );
        expect(
          _refusal(
            MontySet([
              make([_unhashableDict]),
              make([_unhashableList]),
            ]),
          ),
          refusesDict,
        );
        // Two offenders inside one element: the first stored one.
        expect(
          _refusal(
            MontySet([
              make([_unhashableList, _unhashableDict]),
            ]),
          ),
          refusesList,
        );
        expect(
          _refusal(
            MontySet([
              make([_unhashableDict, _unhashableList]),
            ]),
          ),
          refusesDict,
        );
        // Inside a nested member of the element.
        expect(
          _refusal(
            MontySet([
              make([
                const MontyTuple([_unhashableSet]),
              ]),
            ]),
          ),
          refusesSet,
        );
        expect(
          () => ArenaWriter().add(
            MontySet([
              make([const MontyInt(1)]),
            ]),
          ),
          returnsNormally,
        );
      }
    });

    test('a named tuple as key or element', () {
      final bad = _named([const MontyInt(1), _unhashableList]);
      expect(keyIn(bad), refusesList);
      expect(_refusal(MontySet([bad])), refusesList);
      expect(_refusal(MontyFrozenSet([bad])), refusesList);
      // Recursively: the named tuple holds a tuple holding a dict.
      expect(
        keyIn(
          _named([
            const MontyTuple([_unhashableDict]),
          ]),
        ),
        refusesDict,
      );
      final good = _named([const MontyInt(1), const MontyString('x')]);
      expect(
        () => ArenaWriter().add(MontyDict([(good, const MontyInt(1))])),
        returnsNormally,
      );
      expect(() => ArenaWriter().add(MontySet([good])), returnsNormally);
      expect(() => ArenaWriter().add(MontyFrozenSet([good])), returnsNormally);
    });
  });

  group('time and zone fields', () {
    MontyTime? written(MontyTime t) => _roundTrip(t) as MontyTime?;

    test('the valid field ranges', () {
      final top = _time(
        hour: 23,
        minute: 59,
        second: 59,
        microsecond: 999999,
        offset: 86399,
        fold: 1,
      );
      expect(written(top), top);
      final low = _time(
        hour: 0,
        minute: 0,
        second: 0,
        microsecond: 0,
        offset: -86399,
      );
      expect(written(low), low);
      for (final bad in [
        _time(hour: 24),
        _time(hour: -1),
        _time(minute: 60),
        _time(minute: -1),
        _time(second: 60),
        _time(second: -1),
        _time(microsecond: 1000000),
        _time(fold: 2),
        _time(fold: -1),
        _time(offset: 86400),
        _time(offset: -86400),
      ]) {
        expect(_refusal(bad), isNotEmpty);
      }
    });

    test('the writer refuses before encoding', () {
      for (final bad in [
        _time(hour: 24),
        _time(minute: 60),
        _time(second: 60),
        _time(microsecond: 1000000),
        _time(fold: 2),
        _time(offset: 86400),
        _time(offset: -86400),
        // A name needs an offset.
        _time(name: 'UTC'),
      ]) {
        final writer = ArenaWriter();
        expect(() => writer.add(bad), throwsArgumentError, reason: '$bad');
        expect(
          writer.arena.nodes.where(
            (n) => n.whichKind() == pb.MontyNode_Kind.time,
          ),
          isEmpty,
        );
      }
      expect(_refusal(_time(name: 'UTC')), contains('requires offset_seconds'));
      expect(_refusal(_time(fold: 2)), contains('Time.fold'));
    });

    test('a surrogate zone name is dropped, offset kept', () {
      for (final offset in [-3600, 3600, 0]) {
        final (nodes, _) = _write([_time(offset: offset, name: 'Z\uD800')]);
        final node = onlyItem(nodes).time;
        expect(node.hasTimezoneName(), isFalse);
        expect(node.hasOffsetSeconds(), isTrue);
        expect(node.offsetSeconds, offset);
      }
      // A well-formed name is kept next to the same offset.
      final (kept, _) = _write([_time(offset: -3600, name: 'CET')]);
      final keptTime = onlyItem(kept).time;
      expect(keptTime.timezoneName, 'CET');
      expect(keptTime.offsetSeconds, -3600);
    });

    test('fields map, empty name differs from none', () {
      MontyDateTime make({int? offset, String? name}) => MontyDateTime(
        year: 2026,
        month: 10,
        day: 15,
        hour: 13,
        minute: 14,
        second: 15,
        microsecond: 16,
        offsetSeconds: offset,
        timezoneName: name,
      );
      final (nodes, _) = _write([make(offset: -7200, name: 'X')]);
      final d = onlyItem(nodes).datetime;
      expect(
        [d.year, d.month, d.day, d.hour, d.minute, d.second, d.microsecond],
        [2026, 10, 15, 13, 14, 15, 16],
      );
      expect(d.offsetSeconds, -7200);
      expect(d.timezoneName, 'X');
      for (final value in [
        make(),
        make(offset: 0),
        make(offset: 3600, name: ''),
        make(offset: 3600, name: 'X'),
      ]) {
        final back = _roundTrip(value) as MontyDateTime;
        expect(back.timezoneName, value.timezoneName);
        expect(back.offsetSeconds, value.offsetSeconds);
        expect(back, value);
      }
      // On the wire the empty name is present, the absent one is not.
      final (empty, _) = _write([make(offset: 1, name: '')]);
      final (none, _) = _write([make(offset: 1)]);
      expect(onlyItem(empty).datetime.hasTimezoneName(), isTrue);
      expect(onlyItem(none).datetime.hasTimezoneName(), isFalse);
    });
  });

  group('strings and file handles', () {
    test('an output repr, cycle or function sends str', () {
      for (final node in [
        pb.MontyNode(repr: '<object>'),
        pb.MontyNode(cycle: '[...]'),
        pb.MontyNode(function: pb.Function_(name: 'f')),
      ]) {
        final decoded = ArenaReader(pb.Arena(nodeCount: 1, nodes: [node]))[0];
        expect(decoded, isA<MontyString>());
        expect(decoded.runtimeType, MontyString);
        final (nodes, _) = _write([decoded]);
        expect(onlyItem(nodes).whichKind(), pb.MontyNode_Kind.str);
        expect(onlyItem(nodes).str, (decoded as MontyString).value);
      }
    });

    test(
      'a surrogate path never reaches the arena',
      () {
        expect(() => MontyFileHandle('/a\uD800', 'r'), throwsArgumentError);
        expect(() => MontyFileHandle('\uDC00', 'rb'), throwsArgumentError);
        // A well-formed (paired) path is written.
        final (nodes, _) = _write([MontyFileHandle('/\u{1F600}', 'r')]);
        expect(onlyItem(nodes).fileHandle.path, '/\u{1F600}');
      },
    );
  });
}
