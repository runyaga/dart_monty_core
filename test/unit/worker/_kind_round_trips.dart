// Every node kind through the real worker, both ways: Python values decoded
// by the arena reader, and Dart values written by the arena writer that
// Python then checks. Shared by the VM harness
// (test/integration/worker/real_worker_test.dart) and the Chrome one
// (worker_channel_web_test.dart), so both run the same cases.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show montyStdTypeProxy;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

/// One turn on a configured worker.
typedef Turn = Future<pb.ChildEvent> Function(pb.ParentRequest request);

/// A configured worker: its turn, and how to close it.
typedef OpenWorker = Future<(Turn, Future<void> Function())> Function();

const _dt = 'import datetime\n';

/// Python source, and what its value must decode to.
final List<(String, Matcher)> _decodeCases = [
  ('...', equals(const MontyEllipsis())),
  ('NotImplemented', equals(const MontyNotImplemented())),
  (r'b"\x00\xff"', equals(const MontyBytes([0, 255]))),
  (
    '{1: frozenset({2}), 3: {4}}',
    equals(
      const MontyDict([
        (MontyInt(1), MontyFrozenSet([MontyInt(2)])),
        (MontyInt(3), MontySet([MontyInt(4)])),
      ]),
    ),
  ),
  (
    '$_dt(datetime.date(2026, 1, 2), datetime.datetime(2026, 1, 2, 3, 4, '
        '5, 6, tzinfo=datetime.timezone(datetime.timedelta(hours=1), "CET")),'
        ' datetime.time(1, 2, 3, 4, fold=1), datetime.timedelta(-1, 5), '
        'datetime.timezone(datetime.timedelta(hours=-1), "X"))',
    equals(
      const MontyTuple([
        MontyDate(year: 2026, month: 1, day: 2),
        MontyDateTime(
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
        MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4, fold: 1),
        MontyTimeDelta(days: -1, seconds: 5),
        MontyTimeZone(offsetSeconds: -3600, name: 'X'),
      ]),
    ),
  ),
  (
    'ValueError("boom")',
    equals(MontyExceptionValue('ValueError', 'boom')),
  ),
  (
    'KeyError("k")',
    equals(MontyExceptionValue('KeyError', 'k')),
  ),
  ('int', equals(montyStdTypeProxy('type', 'int'))),
  ('ValueError', equals(montyStdTypeProxy('type', 'ValueError'))),
  ('len', equals(montyStdTypeProxy('function', 'len'))),
  ('type', equals(montyStdTypeProxy('type', 'type'))),
  ('from pathlib import Path\nPath("/a/b")', equals(const MontyPath('/a/b'))),
  ('x = []\nx.append(x)\nx', equals(const MontyList([MontyString('[...]')]))),
  // A `repr` key and an equal str collapse, as Python's dict construction
  // collapses them: the first key, the last value.
  (
    '{range(3): 1, "range(0, 3)": 2}',
    equals(
      const MontyDict([
        (MontyString('range(0, 3)'), MontyInt(2)),
      ]),
    ),
  ),
  (
    'import sys\nsys.version_info',
    isA<MontyNamedTuple>().having((t) => t.fieldNames.take(2), 'fields', [
      'major',
      'minor',
    ]),
  ),
  (
    'from dataclasses import dataclass\n@dataclass\nclass P:\n    x: int\n'
        '[P(1), P(2)]',
    isA<MontyList>().having(
      (l) {
        final [a, b] = l.items.cast<MontyClassProxy>();

        return [
          identical(a.classType, b.classType),
          a.classType.name,
          a.classType.isDataclass,
          a.classType.hostDefined,
          a.attrs['x'],
          b.attrs['x'],
        ];
      },
      'instances',
      [true, 'P', true, false, const MontyInt(1), const MontyInt(2)],
    ),
  ),
];

/// Inputs, and a Python expression over them that must be `True`.
final List<(String, Map<String, MontyValue>, String)> _encodeCases = () {
  const shared = MontyList([MontyInt(1)]);

  return [
    ('ellipsis', {'x': const MontyEllipsis()}, 'x is ...'),
    (
      'NotImplemented',
      {'x': const MontyNotImplemented()},
      'x is NotImplemented',
    ),
    (
      'date',
      {'x': const MontyDate(year: 2026, month: 1, day: 2)},
      '${_dt}x == datetime.date(2026, 1, 2)',
    ),
    (
      'aware datetime with a name',
      {
        'x': const MontyDateTime(
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
      },
      '${_dt}x == datetime.datetime(2026, 1, 2, 2, 4, 5, 6, '
          'tzinfo=datetime.timezone.utc) and x.tzname() == "CET"',
    ),
    (
      'time with fold',
      {
        'x': const MontyTime(
          hour: 1,
          minute: 2,
          second: 3,
          microsecond: 4,
          fold: 1,
        ),
      },
      '${_dt}x == datetime.time(1, 2, 3, 4) and x.fold == 1',
    ),
    (
      'timedelta',
      {'x': const MontyTimeDelta(days: -1, seconds: 5)},
      '${_dt}x == datetime.timedelta(days=-1, seconds=5)',
    ),
    (
      'timezone with a name',
      {'x': const MontyTimeZone(offsetSeconds: 3600, name: 'CET')},
      '${_dt}x.utcoffset(None) == datetime.timedelta(hours=1) and '
          'x.tzname(None) == "CET"',
    ),
    (
      'a zone name with no UTF-8 form is dropped',
      {'x': const MontyTimeZone(offsetSeconds: 60, name: '\uD800')},
      '${_dt}x == datetime.timezone(datetime.timedelta(seconds=60)) and '
          'x.tzname(None) == "UTC+00:01"',
    ),
    (
      'exception',
      {'x': MontyExceptionValue('KeyError', 'k')},
      'isinstance(x, KeyError) and x.args == ("k",)',
    ),
    (
      'exception messages with a lone surrogate',
      {
        'v': MontyExceptionValue(
          'ValueError',
          'a\uD800',
        ),
        'k': MontyExceptionValue('KeyError', 'a\uD800'),
      },
      r'''v.args == ("a\ufffd\ufffd\ufffd",) and k.args == ("'a\\ud800'",)''',
    ),
    (
      'builtin function',
      {'x': montyStdTypeProxy('function', 'len')},
      'x([1, 2]) == 2',
    ),
    (
      'builtin type',
      {'x': montyStdTypeProxy('type', 'int')},
      'x is int',
    ),
    (
      'named tuple',
      {
        'x': const MontyNamedTuple(
          typeName: 'P',
          fieldNames: ['a', 'b'],
          values: [MontyInt(1), MontyString('b')],
        ),
      },
      'x.a == 1 and x[1] == "b" and len(x) == 2',
    ),
    ('a container shared across inputs', {'a': shared, 'b': shared}, 'a is b'),
    (
      'a container shared inside one',
      {
        'x': const MontyList([shared, shared]),
      },
      'x[0] is x[1]',
    ),
    (
      'leaves are distinct objects',
      {
        'x': MontyList([
          MontyExceptionValue('ValueError', 'e'),
          MontyExceptionValue('ValueError', 'e'),
        ]),
      },
      'x[0] is not x[1]',
    ),
  ];
}();

pb.ParentRequest _feed(
  String code, [
  Map<String, MontyValue> inputs = const {},
]) {
  final feed = pb.Feed(code: code, cwd: '/');
  if (inputs.isNotEmpty) {
    final writer = ArenaWriter();
    for (final MapEntry(:key, :value) in inputs.entries) {
      feed.inputs.add(pb.NamedRef(name: key, value: writer.add(value)));
    }
    feed.values = writer.arena;
  }

  return pb.ParentRequest(feed: feed);
}

MontyValue _value(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete, reason: '$event');

  return ArenaReader(event.complete.values)[event.complete.value];
}

/// The round-trip tests, each on a fresh worker from [configured], closed
/// at its end.
void kindRoundTripTests(String label, OpenWorker configured) {
  test('every kind decodes from the worker ($label)', () async {
    final (turn, close) = await configured();
    for (final (code, matcher) in _decodeCases) {
      expect(_value(await turn(_feed(code))), matcher, reason: code);
    }
    // A staged kind: checked, but no class for it yet.
    final complex = await turn(_feed('1j'));
    expect(() => _value(complex), throwsUnsupportedError);
    await close();
  });

  test('every kind the worker accepts reaches Python ($label)', () async {
    final (turn, close) = await configured();
    for (final (what, inputs, check) in _encodeCases) {
      expect(
        _value(await turn(_feed(check, inputs))),
        const MontyBool(true),
        reason: what,
      );
    }
    await close();
  });

  test('a sandbox instance sent back is the same object ($label)', () async {
    final (turn, close) = await configured();
    final c = _value(await turn(_feed('class C:\n    pass\nc = C()\nc')));
    expect(c, isA<MontyClassProxy>());
    expect(
      _value(await turn(_feed('x is c', {'x': c}))),
      const MontyBool(true),
    );
    await close();
  });
}
