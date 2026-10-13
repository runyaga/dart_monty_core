// Every node kind through the real worker: Python values decoded by the
// arena reader. Shared by the VM harness
// (test/integration/worker/real_worker_test.dart) and the Chrome one
// (worker_channel_web_test.dart), so both run the same cases.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
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
    equals(const MontyExceptionValue(excType: 'ValueError', message: 'boom')),
  ),
  (
    'KeyError("k")',
    equals(const MontyExceptionValue(excType: 'KeyError', message: 'k')),
  ),
  ('int', equals(const MontyOpaque(MontyOpaqueKind.type, 'int'))),
  ('ValueError', equals(const MontyOpaque(MontyOpaqueKind.type, 'ValueError'))),
  ('len', equals(const MontyOpaque(MontyOpaqueKind.builtin, 'len'))),
  ('type', equals(const MontyOpaque(MontyOpaqueKind.type, 'type'))),
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
        final [a, b] = l.items.cast<MontyClassInstance>();

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

pb.ParentRequest _feed(String code) => pb.ParentRequest(
  feed: pb.Feed(code: code, cwd: '/'),
);

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
}
