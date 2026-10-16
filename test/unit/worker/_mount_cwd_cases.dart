// Expected transitions: session-mount.md, P06 and P-F2's verified-review
// scenarios. Real-worker checks shared by the VM and browser runners.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

final TypeMatcher<MontyRuntimeError> _runtimeError = isA<MontyRuntimeError>();
final TypeMatcher<MontyRuntimeError> _valueError = _runtimeError.having(
  (e) => e.exception.excType,
  'type',
  'ValueError',
);

const _getcwd = 'import os\nos.getcwd()';
const _badType = "value: int = 'wrong'";

Future<MontyValue> _feed(
  MontySession session,
  String code, {
  required bool start,
  List<MountDir>? mount,
  String? cwd,
}) async {
  if (!start) return session.feedRun(code, mount: mount, cwd: cwd);
  final snapshot = await session.feedStart(code, mount: mount, cwd: cwd);
  expect(snapshot, isA<MontyComplete>());

  return (snapshot as MontyComplete).output;
}

void mountCwdTests({List<MountDir> Function(String)? mountsFor}) {
  final mounted = mountsFor != null;
  group('cwd mounted=$mounted', () {
    late Monty pool;
    late MontySession session;
    setUp(() async {
      pool = await Monty.start(maxProcesses: 2);
      session = await pool.checkout();
    });
    tearDown(() async {
      await session.close();
      await pool.close();
    });

    for (final start in [false, true]) {
      group('start=$start', () {
        test('first mount chooses cwd and persists without mounts', () async {
          final expected = mounted ? '/first' : '/';
          expect(
            await _feed(
              session,
              _getcwd,
              start: start,
              mount: mountsFor?.call('/a/../first/'),
            ),
            MontyString(expected),
          );
          expect(await session.feedRun(_getcwd), MontyString(expected));
        });
        test('mount on second feed keeps established root cwd', () async {
          expect(await _feed(session, '1', start: start), const MontyInt(1));
          expect(
            await _feed(
              session,
              _getcwd,
              start: start,
              mount: mountsFor?.call('/second'),
            ),
            const MontyString('/'),
          );
        });
        test('explicit cwd wins and later explicit cwd switches it', () async {
          expect(
            await _feed(
              session,
              _getcwd,
              start: start,
              mount: mountsFor?.call('/first'),
              cwd: '/explicit/',
            ),
            const MontyString('/explicit'),
          );
          expect(
            await _feed(session, _getcwd, start: start, cwd: '/next'),
            const MontyString('/next'),
          );
          expect(await session.feedRun(_getcwd), const MontyString('/next'));
        });
        for (final explicit in [false, true]) {
          test(
            'first typing rejection leaves cwd unset explicit=$explicit',
            () async {
              final typed = await pool.checkout(typeCheck: true);
              addTearDown(typed.close);
              await expectLater(
                _feed(
                  typed,
                  _badType,
                  start: start,
                  mount: mountsFor?.call('/first'),
                  cwd: explicit ? '/explicit' : null,
                ),
                throwsA(isA<MontyTypingError>()),
              );
              expect(
                await _feed(
                  typed,
                  _getcwd,
                  start: start,
                  mount: mountsFor?.call('/second'),
                ),
                MontyString(mounted ? '/second' : '/'),
              );
            },
          );
        }
        test(
          'typing rejection after establishment keeps previous cwd',
          () async {
            final typed = await pool.checkout(typeCheck: true);
            addTearDown(typed.close);
            expect(
              await _feed(typed, _getcwd, start: start, cwd: '/saved'),
              const MontyString('/saved'),
            );
            await expectLater(
              _feed(
                typed,
                _badType,
                start: start,
                cwd: '/rejected',
                mount: mountsFor?.call('/first'),
              ),
              throwsA(isA<MontyTypingError>()),
            );
            expect(
              await _feed(
                typed,
                _getcwd,
                start: start,
                mount: mountsFor?.call('/second'),
              ),
              const MontyString('/saved'),
            );
          },
        );
        for (final syntax in [true, false]) {
          test(
            'sent ${syntax ? 'syntax' : 'runtime'} error establishes cwd',
            () async {
              await expectLater(
                _feed(
                  session,
                  syntax ? 'if :' : '1 / 0',
                  start: start,
                  mount: mountsFor?.call('/first'),
                  cwd: mounted ? null : '/sent',
                ),
                throwsA(
                  syntax ? isA<MontySyntaxError>() : _runtimeError,
                ),
              );
              expect(
                await _feed(
                  session,
                  _getcwd,
                  start: start,
                  mount: mountsFor?.call('/second'),
                ),
                MontyString(mounted ? '/first' : '/sent'),
              );
            },
          );
        }
        test(
          'load session preserves saved cwd against later first mount',
          () async {
            await session.feedRun('1', cwd: '/saved');
            final state = await session.dump();
            final restored = await pool.checkout();
            addTearDown(restored.close);
            await restored.loadSession(state);
            expect(
              await _feed(
                restored,
                _getcwd,
                start: start,
                mount: mountsFor?.call('/other'),
              ),
              const MontyString('/saved'),
            );
          },
        );
        test(
          'load snapshot preserves saved cwd through resume and next feed',
          () async {
            final snapshot =
                await session.feedStart(
                      "import os\nos.getenv('WAIT')\nos.getcwd()",
                      cwd: '/saved',
                    )
                    as FunctionSnapshot;
            final state = await snapshot.dump();
            final restored = await pool.checkout();
            addTearDown(restored.close);
            final loaded =
                await restored.loadSnapshot(
                      state,
                      mount: mountsFor?.call('/restore'),
                    )
                    as FunctionSnapshot;
            final done = await loaded.resume(
              const ExternalReturnValue(MontyNone()),
            );
            expect(
              done,
              isA<MontyComplete>().having(
                (s) => s.output,
                'output',
                const MontyString('/saved'),
              ),
            );
            expect(
              await _feed(
                restored,
                _getcwd,
                start: start,
                mount: mountsFor?.call('/other'),
              ),
              const MontyString('/saved'),
            );
          },
        );
        for (final cwd in ['', 'relative', '/nul\u0000']) {
          test(
            'invalid cwd wins over overlap before feed cwd=${cwd.codeUnits}',
            () async {
              final mounts = mountsFor?.call('/first');
              final overlap = mounts == null ? null : [...mounts, ...mounts];
              await expectLater(
                _feed(
                  session,
                  'sent = True',
                  start: start,
                  mount: overlap,
                  cwd: cwd,
                ),
                throwsA(
                  _valueError
                      .having(
                        (e) => e.exception.message,
                        'message',
                        startsWith('cwd must'),
                      )
                      .having((e) => e.traceback, 'traceback', isEmpty),
                ),
              );
              if (overlap != null) {
                await expectLater(
                  _feed(
                    session,
                    'sent = True',
                    start: start,
                    mount: overlap,
                    cwd: '/valid',
                  ),
                  throwsA(
                    _valueError
                        .having(
                          (e) => e.exception.message,
                          'message',
                          contains('overlaps'),
                        )
                        .having((e) => e.traceback, 'traceback', isEmpty),
                  ),
                );
              }
              expect(
                await _feed(
                  session,
                  _getcwd,
                  start: start,
                  mount: mountsFor?.call('/second'),
                ),
                MontyString(mounted ? '/second' : '/'),
              );
              await expectLater(
                session.feedRun('sent'),
                throwsA(
                  _runtimeError.having(
                    (e) => e.exception.excType,
                    'type',
                    'NameError',
                  ),
                ),
              );
            },
          );
        }
      });
    }
  });
}
