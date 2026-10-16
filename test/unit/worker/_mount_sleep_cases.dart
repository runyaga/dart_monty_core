// Expected routing: F session-mount contract and P-F2 verified sleep cases.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void mountSleepTests({List<MountDir> Function()? mounts}) {
  for (final (name, code) in [
    ('system.sleep', 'import time\ntime.sleep(0)\n42'),
    ('system.async_sleep', 'import asyncio\nawait asyncio.sleep(0.001)\n42'),
  ]) {
    for (final automatic in [true, false]) {
      test(
        '$name feedStart surfaces then dispatches auto=$automatic',
        () async {
          await Monty.withPool((pool) async {
            await pool.withSession((session) async {
              final seen = <String>[];
              MontyValue handler(
                String called,
                List<MontyValue> _,
                Map<String, MontyValue> _,
              ) {
                seen.add(called);

                return const MontyNone();
              }

              final snapshot = await session.feedStart(
                code,
                mount: mounts?.call(),
                os: handler,
              );
              expect(snapshot, isA<FunctionSnapshot>());
              final call = snapshot as FunctionSnapshot;
              expect(call.functionName, name);
              expect(call.isOsFunction, isTrue);
              expect(seen, isEmpty);
              final done = automatic
                  ? await call.resumeAuto()
                  : await call.resume(
                      ExternalReturnValue(
                        handler(call.functionName, call.args, call.kwargs),
                      ),
                    );
              expect(
                done,
                isA<MontyComplete>().having(
                  (s) => s.output,
                  'output',
                  const MontyInt(42),
                ),
              );
              expect(seen, [name]);
            });
          }, maxProcesses: 1);
        },
      );
    }
    test('$name feedRun stays automatic', () async {
      await Monty.withPool((pool) async {
        await pool.withSession((session) async {
          var calls = 0;
          expect(
            await session.feedRun(
              code,
              mount: mounts?.call(),
              os: (n, a, k) {
                calls++;

                return const MontyNone();
              },
            ),
            const MontyInt(42),
          );
          expect(calls, 0);
        });
      }, maxProcesses: 1);
    });
    test('$name feedStart dispatches zero-cap OSAccess', () async {
      await Monty.withPool((pool) async {
        await pool.withSession((session) async {
          final snapshot = await session.feedStart(
            code,
            os: OSAccess(maxSleep: Duration.zero).call,
          );
          expect(snapshot, isA<FunctionSnapshot>());
          expect(
            await (snapshot as FunctionSnapshot).resumeAuto(),
            isA<MontyComplete>().having(
              (s) => s.output,
              'output',
              const MontyInt(42),
            ),
          );
        });
      }, maxProcesses: 1);
    });
    test('$name call_host reaches handler', () async {
      await Monty.withPool((pool) async {
        await pool.withSession((session) async {
          final seen = <String>[];
          expect(
            await session.feedRun(
              code,
              os: (n, a, k) {
                seen.add(n);

                return const MontyNone();
              },
            ),
            const MontyInt(42),
          );
          expect(seen, [
            if (name == 'system.sleep') 'time.sleep' else 'asyncio.sleep',
          ]);
        }, osPolicy: const OsPolicy(sleep: 'call_host'));
      }, maxProcesses: 1);
    });
  }
}
