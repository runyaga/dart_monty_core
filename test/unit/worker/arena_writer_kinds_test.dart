// The arena writer: every kind the worker accepts, sharing as upstream's
// encoder shares, and the outbound checks that mirror the reader's. Pure
// Dart, so the unit and unit_web steps run it on the VM, dart2js and
// dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '../../_accessors.dart';

/// [value] written, sent over the wire and read back.
MontyValue _roundTrip(MontyValue value) {
  final writer = ArenaWriter();
  final root = writer.add(value);

  return ArenaReader(pb.Arena.fromBuffer(writer.arena.writeToBuffer()))[root];
}

/// The single node [value] is written as.
pb.MontyNode _only(MontyValue value) =>
    onlyItem((ArenaWriter()..add(value)).arena.nodes);

Matcher _refused(String fragment) => throwsA(
  isA<ArgumentError>().having(
    (e) => '${e.message}',
    'message',
    contains(fragment),
  ),
);

/// dart2js, where an `int` is a double.
bool get _isJs => identical(1, 1.0);

const _classId = '0123abcd-0000-4000-8000-00000000cafe';

MontyClassType _class({Map<String, MontyValue> attrs = const {}}) =>
    MontyClassType(
      name: 'P',
      id: _classId,
      hostDefined: true,
      isDataclass: true,
      attrs: attrs,
    );

MontyClassInstance _instance(
  MontyClassType type,
  String suffix, [
  Map<String, MontyValue> attrs = const {},
]) => MontyClassInstance(
  classType: type,
  instanceId: '00000000-0000-4000-8000-0000000000$suffix',
  attrs: attrs,
);

void main() {
  group('every kind the worker accepts round-trips', () {
    final values = <String, MontyValue>{
      'ellipsis': const MontyEllipsis(),
      'NotImplemented': const MontyNotImplemented(),
      'date': const MontyDate(year: 2026, month: 1, day: 2),
      'naive datetime': const MontyDateTime(
        year: 1,
        month: 12,
        day: 31,
        hour: 23,
        minute: 59,
        second: 59,
        microsecond: 999999,
      ),
      'aware datetime with a name': const MontyDateTime(
        year: 9999,
        month: 2,
        day: 28,
        hour: 0,
        minute: 0,
        second: 0,
        offsetSeconds: -86399,
        timezoneName: 'W',
      ),
      'time with fold and an empty name': const MontyTime(
        hour: 0,
        minute: 0,
        second: 0,
        microsecond: 0,
        offsetSeconds: 0,
        timezoneName: '',
        fold: 1,
      ),
      'timedelta': const MontyTimeDelta(
        days: -999999999,
        seconds: 86399,
        microseconds: 999999,
      ),
      'timezone': const MontyTimeZone(offsetSeconds: 3600, name: 'CET'),
      'utc': const MontyTimeZone(offsetSeconds: 0),
      'exception': const MontyExceptionValue(excType: 'KeyError', message: 'k'),
      'exception without a message': const MontyExceptionValue(
        excType: 'ValueError',
        message: '',
      ),
      'builtin type': const MontyOpaque(MontyOpaqueKind.type, 'datetime.date'),
      'builtin function': const MontyOpaque(
        MontyOpaqueKind.builtin,
        'object.__setattr__',
      ),
      'file handle': const MontyFileHandle(path: '/x', mode: 'ab', position: 7),
      'named tuple': const MontyNamedTuple(
        typeName: 'os.stat_result',
        fieldNames: ['st_mode', 'st_size'],
        values: [MontyInt(1), MontyList([])],
      ),
      'class instance': _instance(
        _class(attrs: {'k': const MontyInt(1)}),
        '01',
        {'x': const MontyString('y')},
      ),
    };
    for (final MapEntry(:key, :value) in values.entries) {
      test(key, () {
        final back = _roundTrip(value);
        expect(back, value);
        expect(back.runtimeType, value.runtimeType);
      });
    }

    test('a file mode is sent in its canonical form', () {
      expect(
        _only(const MontyFileHandle(path: '/x', mode: 'tr')).fileHandle.mode,
        'r',
      );
    });

    test('the class of an instance is a host or sandbox type node', () {
      final writer = ArenaWriter()..add(_instance(_class(), '01'));
      final type = itemAt(writer.arena.nodes, 0).type;
      expect(type.origin, 3);
      expect(type.isDataclass, isTrue);
      expect(type.hasAttrs(), isFalse);
      expect(type.id.data, hasLength(16));
      const sandbox = MontyClassType(
        name: 'S',
        id: _classId,
        hostDefined: false,
        isDataclass: false,
        attrs: {},
      );
      final nodes = (ArenaWriter()..add(_instance(sandbox, '01'))).arena.nodes;
      expect(itemAt(nodes, 0).type.origin, 2);
      // An instance's attrs are always present, even empty.
      expect(itemAt(nodes, 1).classInstance.hasAttrs(), isTrue);
    });

    test('functionNode builds the function arm for a host callable', () {
      final node = functionNode('f', docstring: 'd');
      expect(node.function.name, 'f');
      expect(node.function.docstring, 'd');
      expect(functionNode('g').function.hasDocstring(), isFalse);
    });
  });

  group('sharing follows upstream encoder', () {
    test('containers are one node per object, across adds', () {
      const shared = MontyList([MontyInt(1)]);
      final writer = ArenaWriter();
      final a = writer.add(const MontyTuple([shared, shared]));
      final b = writer.add(shared);
      final items = itemAt(writer.arena.nodes, a).tuple.items;
      expect(items, [b, b]);
    });

    test('leaves are a fresh node at each reference', () {
      const e = MontyExceptionValue(excType: 'ValueError', message: 'm');
      const s = MontyString('s');
      const h = MontyFileHandle(path: '/x', mode: 'r');
      final writer = ArenaWriter()..add(const MontyList([e, e, s, s, h, h]));
      final items = writer.arena.nodes.lastOrNull?.list.items;
      expect(items?.toSet(), hasLength(6));
    });

    test('a 64-level shared DAG: one node per list, fresh leaves', () {
      MontyValue v = const MontyNone();
      for (var i = 0; i < 64; i++) {
        v = MontyList([v, v]);
      }
      final writer = ArenaWriter()..add(v);
      // The innermost list holds two None leaves.
      expect(writer.arena.nodes, hasLength(66));
    });

    test('an attribute-less class is one node per id, across objects', () {
      // Two distinct class objects with one id.
      final classes = [for (var i = 0; i < 2; i++) _class()];
      final writer = ArenaWriter();
      final a = writer.add(_instance(itemAt(classes, 0), '01'));
      final b = writer.add(_instance(itemAt(classes, 1), '02'));
      final nodes = writer.arena.nodes;
      expect(
        itemAt(nodes, a).classInstance.classType,
        itemAt(nodes, b).classInstance.classType,
      );
      expect(nodes.where((n) => n.hasType()), hasLength(1));
    });

    test('a class id is one uuid, whatever the case of its digits', () {
      final upper = MontyClassType(
        name: 'P',
        id: _classId.toUpperCase(),
        hostDefined: true,
        isDataclass: true,
        attrs: const {},
      );
      final writer = ArenaWriter()
        ..add(_instance(_class(), '01'))
        ..add(_instance(upper, '02'));
      expect(writer.arena.nodes.where((n) => n.hasType()), hasLength(1));
    });

    test('a class with attributes is a node per reference', () {
      final type = _class(attrs: {'k': const MontyInt(1)});
      final writer = ArenaWriter()
        ..add(MontyList([_instance(type, '01'), _instance(type, '02')]));
      expect(writer.arena.nodes.where((n) => n.hasType()), hasLength(2));
    });

    test('decoded, two instances of one class share it again', () {
      final type = _class();
      final back =
          _roundTrip(
                MontyList([_instance(type, '01'), _instance(type, '02')]),
              )
              as MontyList;
      expect(
        identical(
          (itemAt(back.items, 0) as MontyClassInstance).classType,
          (itemAt(back.items, 1) as MontyClassInstance).classType,
        ),
        isTrue,
      );
    });

    test('a cycle through an instance attribute is refused', () {
      final attrs = <String, MontyValue>{};
      final i = _instance(_class(), '01', attrs);
      attrs['self'] = MontyList([i]);
      expect(() => ArenaWriter().add(i), _refused('contains itself'));
    });
  });

  group('outbound checks mirror the reader', () {
    test('bytes outside 0..255', () {
      expect(
        () => ArenaWriter().add(const MontyBytes([0, 256])),
        _refused('byte 256 at index 1'),
      );
      expect(
        () => ArenaWriter().add(const MontyBytes([-1])),
        _refused('byte -1'),
      );
    });

    test('unpaired surrogates; a valid pair is the control', () {
      expect(_only(const MontyString('\u{1F600}')).str, '\u{1F600}');
      final surrogate = _refused('unpaired UTF-16 surrogate');
      for (final bad in ['a\uD800', '\uDC00b', '\uDC00\uD800']) {
        expect(
          () => ArenaWriter().add(MontyString(bad)),
          surrogate,
        );
        expect(
          () => ArenaWriter().add(MontyPath(bad)),
          surrogate,
        );
        expect(
          () => ArenaWriter().add(
            MontyNamedTuple(
              typeName: 'P',
              fieldNames: [bad],
              values: const [MontyNone()],
            ),
          ),
          surrogate,
        );
        expect(
          () => ArenaWriter().add(
            _instance(_class(), '01', {bad: const MontyNone()}),
          ),
          surrogate,
        );
      }
    });

    test('exception messages: lossy, a KeyError as its repr', () {
      expect(
        _only(
          const MontyExceptionValue(excType: 'ValueError', message: 'a\uD800b'),
        ).exception.arg,
        // PyO3: surrogatepass bytes ED A0 80, each decoded to U+FFFD.
        'a\uFFFD\uFFFD\uFFFDb',
      );
      expect(
        _only(
          const MontyExceptionValue(excType: 'KeyError', message: 'a\uD800'),
        ).exception.arg,
        r"'a\ud800'",
      );
      expect(
        _only(
          const MontyExceptionValue(excType: 'KeyError', message: 'k'),
        ).exception.arg,
        'k',
      );
    });

    test("an exception without a message is sent with argument ''", () {
      // Upstream's encoder sends str(exc), which is '' for RuntimeError(),
      // so the sandbox sees RuntimeError(''), not RuntimeError().
      for (final type in ['RuntimeError', 'KeyError']) {
        final e = _only(MontyExceptionValue(excType: type)).exception;
        expect(e.hasArg(), isTrue, reason: type);
        expect(e.arg, '', reason: type);
      }
    });

    test('a zone name with no UTF-8 form is dropped; the offset stays', () {
      final zone = _only(
        const MontyTimeZone(offsetSeconds: 60, name: '\uD800'),
      ).timezone;
      expect(zone.offsetSeconds, 60);
      expect(zone.hasName(), isFalse);
      final time = _only(
        const MontyTime(
          hour: 1,
          minute: 0,
          second: 0,
          microsecond: 0,
          offsetSeconds: 60,
          timezoneName: '\uDC00',
        ),
      ).time;
      expect(time.hasOffsetSeconds(), isTrue);
      expect(time.hasTimezoneName(), isFalse);
      final dt = _only(
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
          offsetSeconds: 0,
          timezoneName: '\uD800',
        ),
      ).datetime;
      expect(dt.hasOffsetSeconds(), isTrue);
      expect(dt.hasTimezoneName(), isFalse);
      // A valid name is kept.
      expect(
        _only(const MontyTimeZone(offsetSeconds: 60, name: 'Z')).timezone.name,
        'Z',
      );
    });

    test('temporal ranges, as the worker states them', () {
      final cases = <MontyValue, String>{
        const MontyDate(year: 2026, month: 2, day: 29):
            'invalid value for Date.day: 29 is outside the range 1..=28',
        const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0):
            'invalid value for Time.hour: 24 is outside the range 0..=23',
        const MontyTime(hour: 0, minute: 0, second: 0, microsecond: 0, fold: 2):
            'Time.fold: 2',
        const MontyTime(
          hour: 0,
          minute: 0,
          second: 0,
          microsecond: 0,
          timezoneName: 'X',
        ): 'timezone_name requires offset_seconds',
        const MontyDateTime(
          year: 10000,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
        ): 'DateTime.year: 10000',
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
          microsecond: 1000000,
        ): 'DateTime.microsecond: 1000000 exceeds maximum 999999',
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
          offsetSeconds: 86400,
        ): 'DateTime.offset_seconds: 86400',
        const MontyTimeZone(offsetSeconds: -86400):
            'TimeZone.offset_seconds: -86400',
        const MontyTimeDelta(days: 0, seconds: 86400):
            'TimeDelta.seconds: 86400 is outside the normalized range',
        const MontyTimeDelta(days: 0, seconds: 0, microseconds: -1):
            'TimeDelta.microseconds: -1',
        const MontyTimeDelta(days: 1000000000, seconds: 0):
            'days=1000000000; must have magnitude <= 999999999',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(() => ArenaWriter().add(key), _refused(value), reason: '$key');
      }
    });

    test('names the worker does not know', () {
      expect(
        () => ArenaWriter().add(
          const MontyExceptionValue(excType: 'Oops', message: 'm'),
        ),
        _refused('unknown exception type "Oops"'),
      );
      expect(
        () => ArenaWriter().add(const MontyOpaque(MontyOpaqueKind.type, 'Int')),
        _refused('unknown type name "Int"'),
      );
      expect(
        () => ArenaWriter().add(
          const MontyOpaque(MontyOpaqueKind.builtin, 'Len'),
        ),
        _refused('unknown builtin function "Len"'),
      );
    });

    test('renderings that name nothing the sandbox can rebuild', () {
      for (final kind in [
        MontyOpaqueKind.function,
        MontyOpaqueKind.repr,
        MontyOpaqueKind.cycle,
      ]) {
        expect(
          () => ArenaWriter().add(MontyOpaque(kind, 'x')),
          _refused('cannot be sent back'),
        );
      }
    });

    test('file modes and positions', () {
      final outOfRange = _refused('outside 0..2^64-1');
      expect(
        () => ArenaWriter().add(const MontyFileHandle(path: '/x', mode: 'r+')),
        _refused('invalid file mode "r+"'),
      );
      expect(
        () => ArenaWriter().add(
          const MontyFileHandle(path: '/x', mode: 'r', position: -1),
        ),
        outOfRange,
      );
      if (_isJs) {
        // Only dart2js holds 2^64 in an int.
        final two64 = (BigInt.one << 64).toDouble().toInt();
        expect(
          () => ArenaWriter().add(
            MontyFileHandle(path: '/x', mode: 'r', position: two64),
          ),
          outOfRange,
        );
      }
    });

    test('dict keys and set members Python could not hash', () {
      const listInTuple = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyList([])],
      );
      final cases = <MontyValue, String>{
        const MontySet([listInTuple]): 'list',
        const MontyFrozenSet([
          MontyTuple([MontySet([])]),
        ]): 'set',
        const MontyDict([(MontyDict([]), MontyNone())]): 'dict',
        MontySet([_instance(_class(), '01')]): 'MontyClassProxy',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
          () => ArenaWriter().add(key),
          _refused("TypeError: unhashable type: '$value'"),
        );
      }
      // Hashable controls, a deep one included.
      MontyValue deep = const MontyInt(1);
      for (var i = 0; i < 100000; i++) {
        deep = MontyTuple([deep]);
      }
      for (final ok in [
        const MontySet([
          MontyTuple([MontyInt(1), MontyFrozenSet([])]),
        ]),
        MontyDict([(deep, const MontyNone())]),
      ]) {
        expect(() => ArenaWriter().add(ok), returnsNormally);
      }
    });

    test('named tuples Python could not build', () {
      expect(
        () => ArenaWriter().add(
          const MontyNamedTuple(
            typeName: 'P',
            fieldNames: ['x', 'y'],
            values: [MontyNone()],
          ),
        ),
        _refused('Expected 2 arguments, got 1'),
      );
      expect(
        () => ArenaWriter().add(
          const MontyNamedTuple(typeName: 'def', fieldNames: [], values: []),
        ),
        _refused('cannot be a keyword'),
      );
    });

    test('class and instance ids must be uuids', () {
      expect(
        () => ArenaWriter().add(
          MontyClassInstance(
            classType: _class(),
            instanceId: 'nope',
            attrs: const {},
          ),
        ),
        _refused('id "nope" is not a uuid'),
      );
      // The same 16 bytes, but not in the canonical 8-4-4-4-12 form.
      expect(
        () => ArenaWriter().add(
          MontyClassInstance(
            classType: _class(),
            instanceId: '0123abcd00004000800000000000cafe----',
            attrs: const {},
          ),
        ),
        _refused('is not a uuid'),
      );
    });

    test('a MontyDataclass has no node', () {
      expect(
        () => ArenaWriter().add(
          const MontyDataclass(name: 'D', typeId: 1, fieldNames: [], attrs: {}),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
