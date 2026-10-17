// Typed values handed back to the sandbox keep their Python type, as in
// pydantic_monty 1.1.0 (measured per case: the host receives the typed value
// and the sandbox sees the same type). A wrapper's dartValue map is refused
// before it can become a dict with `__type` keys or instance UUIDs.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

const _probe = "{'type': type(x).__name__, 'is_dict': isinstance(x, dict)}";

/// Script, and `type(x).__name__` in the sandbox after the value is handed
/// back (identical in pydantic_monty 1.1.0).
const _namedtuple =
    "import collections\nN = collections.namedtuple('N', 'a b')\nN(1, 2)";
const _timezone =
    'import datetime\ndatetime.timezone(datetime.timedelta(hours=2), "X")';

const List<(String, String, String)> _cases = [
  ('MontyPath', "import pathlib\npathlib.Path('/a/b')", 'PosixPath'),
  ('namedtuple', _namedtuple, 'namedtuple'),
  ('timezone', _timezone, 'timezone'),
  ('bytes', r"b'\x00\x01'", 'bytes'),
  ('tuple', '(1, 2, 3)', 'tuple'),
];

const _dataclass =
    'from dataclasses import dataclass\n'
    '@dataclass\nclass P:\n    x: int\n    y: str\nP(1, "a")';

Future<MontySession> _session() async {
  final worker = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(maxProcesses: 1, workerLocation: worker.path);
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);

  return session;
}

Map<String, Object?> _seen(MontyValue v) => switch (v.dartValue) {
  final Map<Object?, Object?> m => m.cast(),
  _ => throw StateError('not a dict: $v'),
};

void main() {
  group('a typed value handed back as an input', () {
    for (final (name, script, type) in _cases) {
      test('$name keeps its type', () async {
        final s = await _session();
        final v = await s.feedRun(script);
        final r = await s.feedRun(_probe, inputs: {'x': v});
        expect(_seen(r), {'type': type, 'is_dict': false});
      });
    }

    test('a class instance is refused as upstream refuses it', () async {
      final s = await _session();
      final v = await s.feedRun(_dataclass);
      expect(
        s.feedRun(_probe, inputs: {'x': v}),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.toString(),
            'message',
            contains('no longer exists'),
          ),
        ),
      );
    });
  });

  group('a typed value returned from a host function', () {
    for (final (name, script, type) in _cases) {
      test('$name keeps its type', () async {
        final s = await _session();
        final v = await s.feedRun(script);
        await s.feedRun(
          'x = hv()',
          externalLookup: {
            'hv': MontyHostFunction('hv', (_, _) async => v),
          },
        );
        final r = await s.feedRun(_probe);
        expect(_seen(r), {'type': type, 'is_dict': false});
      });
    }
  });

  group('the plain Dart projection', () {
    test('bytes through dartValue stay bytes', () async {
      final s = await _session();
      final v = await s.feedRun(r"b'\x00\x01'");
      final r = await s.feedRun(
        _probe,
        inputs: {'x': MontyValue.fromDart(v.dartValue)},
      );
      expect(_seen(r), {'type': 'bytes', 'is_dict': false});
    });

    for (final (name, script) in [
      ('namedtuple', _namedtuple),
      ('timezone', _timezone),
      ('class instance', _dataclass),
    ]) {
      test('the dartValue map of a $name is refused', () async {
        final s = await _session();
        final v = await s.feedRun(script);
        expect(() => MontyValue.fromDart(v.dartValue), throwsArgumentError);
      });
    }
  });
}
