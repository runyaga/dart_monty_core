// Checking configuration changes the worker's diagnostics and accepted code.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

Future<Monty> _pool() async {
  final pool = await Monty.start(maxProcesses: 1);
  addTearDown(pool.close);

  return pool;
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'supplied stubs govern each feed unless skipped',
    () async {
      final session = await protoBoundedSession(
        typeCheck: true,
        typeCheckStubs: 'def f(x: int) -> int: ...',
      );
      final functions = {
        'f': MontyHostFunction(
          'f',
          (args, _) => args.singleOrNull ?? fail('expected one argument'),
        ),
      };
      expect(
        await session.feedRun('f(7)', externalLookup: functions),
        const MontyInt(7),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          session.feedRun('f("wrong")', externalLookup: functions),
          throwsA(
            isA<MontyTypingError>().having(
              (e) => e.toString(),
              'diagnostic',
              contains('invalid-argument-type'),
            ),
          ),
        );
      }
      expect(
        await session.feedRun(
          'f("wrong")',
          externalLookup: functions,
          skipTypeCheck: true,
        ),
        const MontyString('wrong'),
      );
      expect(
        await session.feedRun('f(42)', externalLookup: functions),
        const MontyInt(42),
      );
    },
  );

  for (final format in [
    'full',
    'concise',
    'azure',
    'json',
    'jsonlines',
    'rdjson',
    'pylint',
    'gitlab',
    'github',
  ]) {
    test(
      'ANSI color is limited to full and concise ($format)',
      () async {
        final pool = await _pool();
        for (final color in [false, true]) {
          await pool.withSession(
            (session) async {
              await expectLater(
                session.feedRun('x: int = "wrong"'),
                throwsA(
                  isA<MontyTypingError>()
                      .having(
                        (e) => e.toString(),
                        'assignment diagnostic',
                        contains('not assignable'),
                      )
                      .having(
                        (e) => e.toString().contains('\u001b['),
                        'ANSI escapes',
                        color && (format == 'full' || format == 'concise'),
                      ),
                ),
              );
              expect(await session.feedRun('42'), const MontyInt(42));
            },
            typeCheck: true,
            typeCheckFormat: format,
            typeCheckColor: color,
          );
        }
      },
    );
  }

  test(
    'annotations retain each operand at byte boundaries',
    () async {
      final pool = await _pool();
      final messages = <int?, String>{};
      for (final limit in [null, 0, 119, 120, 121]) {
        await pool.withSession((session) async {
          final result = await session.feedRun(
            'left = "é" * 59 + "abc" + "L" * 200\n'
            'right = "é" * 59 + "xyz" + "R" * 200\n'
            'try:\n    assert left == right\n'
            'except AssertionError as e:\n    result = str(e)\nresult',
          );
          messages[limit] = (result as MontyString).value;
        }, assertMessageAnnotations: limit);
      }
      String message(String left, String right) => "assert '$left == '$right";
      final prefix = 'é' * 59;
      expect(messages[0], '');
      expect(messages[119], message('$prefix…', '$prefix…'));
      expect(messages[120], message('${prefix}a…', '${prefix}x…'));
      expect(messages[121], message('${prefix}ab…', '${prefix}xy…'));
      expect(messages[null], messages[120]);
    },
  );
}
