// Typed values handed back keep their Python type as in pydantic_monty 1.1.0;
// dartValue maps are refused while caller-built maps remain dicts.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

typedef WithTypedValueSession =
    Future<void> Function(Future<void> Function(MontySession session) body);

const _probe = "{'type': type(x).__name__, 'is_dict': isinstance(x, dict)}";

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

Map<String, Object?> _seen(MontyValue v) => switch (v.dartValue) {
  final Map<Object?, Object?> m => m.cast(),
  _ => throw StateError('not a dict: $v'),
};

void typedValueRoundTripTests(
  String label,
  WithTypedValueSession withSession,
) {
  group('a typed value handed back as an input', () {
    for (final (name, script, type) in _cases) {
      test('$name keeps its type ($label)', () async {
        await withSession((session) async {
          final v = await session.feedRun(script);
          final r = await session.feedRun(_probe, inputs: {'x': v});
          expect(_seen(r), {'type': type, 'is_dict': false});
        });
      });
    }

    test(
      'a class instance is refused as upstream refuses it ($label)',
      () async {
        await withSession((session) async {
          final v = await session.feedRun(_dataclass);
          await expectLater(
            session.feedRun(_probe, inputs: {'x': v}),
            throwsA(
              isA<MontyRuntimeError>().having(
                (e) => e.toString(),
                'message',
                contains('no longer exists'),
              ),
            ),
          );
        });
      },
    );
  });

  group('a typed value returned from a host function', () {
    for (final (name, script, type) in _cases) {
      test('$name keeps its type ($label)', () async {
        await withSession((session) async {
          final v = await session.feedRun(script);
          await session.feedRun(
            'x = hv()',
            externalLookup: {
              'hv': MontyHostFunction('hv', (_, _) async => v),
            },
          );
          final r = await session.feedRun(_probe);
          expect(_seen(r), {'type': type, 'is_dict': false});
        });
      });
    }
  });

  group('the plain Dart projection', () {
    test('bytes through dartValue stay bytes ($label)', () async {
      await withSession((session) async {
        final v = await session.feedRun(r"b'\x00\x01'");
        final r = await session.feedRun(
          _probe,
          inputs: {'x': MontyValue.fromDart(v.dartValue)},
        );
        expect(_seen(r), {'type': 'bytes', 'is_dict': false});
      });
    });

    for (final (name, script) in [
      ('namedtuple', _namedtuple),
      ('timezone', _timezone),
      ('class instance', _dataclass),
    ]) {
      test('the dartValue map of a $name is refused ($label)', () async {
        await withSession((session) async {
          final v = await session.feedRun(script);
          expect(() => MontyValue.fromDart(v.dartValue), throwsArgumentError);
        });
      });
    }

    test(
      'a copy of the dartValue map of a namedtuple reaches the sandbox '
      'as a dict ($label)',
      () async {
        await withSession((session) async {
          final v = await session.feedRun(_namedtuple);
          final copy = switch (v.dartValue) {
            final Map<String, Object?> m => Map<String, Object?>.of(m),
            final other => throw StateError('not a map: $other'),
          };
          final r = await session.feedRun(
            _probe,
            inputs: {'x': MontyValue.fromDart(copy)},
          );
          expect(_seen(r), {'type': 'dict', 'is_dict': true});
        });
      },
    );
  });
}
