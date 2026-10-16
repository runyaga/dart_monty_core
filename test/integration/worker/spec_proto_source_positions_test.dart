// Upstream source ranges at real suspensions, across feeds and eval/exec.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show SuspendedSnapshot;
import 'package:test/test.dart';

import '../../unit/worker/_host_cases.dart' show Point, pointClass;
import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

void _position(
  SuspendedSnapshot snapshot,
  String filename,
  int start,
  int end,
) {
  expect(snapshot.position.filename, filename);
  expect(snapshot.position.start, start);
  expect(snapshot.position.end, end);
}

Future<void> _complete(FunctionSnapshot call) async {
  final done = await call.resume(const ExternalReturnValue(MontyInt(42)));
  expect((done as MontyComplete).output, const MontyInt(42));
}

Future<FunctionSnapshot> _startCall(MontySession session) async =>
    await session.feedStart('f()') as FunctionSnapshot;

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'lazy attribute position and script name',
    () async {
      final session = await protoBoundedSession();
      final object = ClassInstance(
        const Point(3, 4),
        classType: ClassType(pointClass),
        policies: (
          eagerAttrs: <String>[],
          lazyAttrs: ['norm1'],
          allowedMethods: <String>[],
        ),
      );
      final lookup =
          await session.feedStart('v = 1\np.norm1', inputs: {'p': object})
              as NameLookupSnapshot;
      _position(lookup, '<python-input-0>', 6, 13);
      expect(lookup.scriptName, 'spec.py');
      expect(lookup.variableName, 'norm1');
      expect(
        (await lookup.resumeAuto() as MontyComplete).output,
        const MontyInt(7),
      );
    },
  );

  test(
    'feed, earlier definition, eval and exec retain source names',
    () async {
      final session = await protoBoundedSession();
      final direct = await _startCall(session);
      _position(direct, '<python-input-0>', 0, 3);
      await _complete(direct);
      await session.feedRun('def earlier():\n    return f()');
      final earlier = await session.feedStart('earlier()') as FunctionSnapshot;
      _position(earlier, '<python-input-1>', 26, 29);
      await _complete(earlier);
      final eval = await session.feedStart("eval('  f()')") as FunctionSnapshot;
      _position(eval, '<string>', 0, 3);
      await _complete(eval);
      final exec = await session.feedStart("exec('f()')") as FunctionSnapshot;
      _position(exec, '<string>', 0, 3);
      expect(
        (await exec.resume(const ExternalReturnValue(MontyInt(42)))
                as MontyComplete)
            .output,
        const MontyNone(),
      );
    },
  );

  test(
    'only compilation advances input numbers',
    () async {
      final session = await protoBoundedSession(
        typeCheck: true,
        typeCheckStubs: 'def f() -> int: ...',
      );
      expect(await session.feedRun(''), const MontyNone());
      await expectLater(
        session.feedRun('x: int = "bad"'),
        throwsA(isA<MontyTypingError>()),
      );
      for (final number in [0, 2]) {
        if (number == 2) {
          await expectLater(
            session.feedRun('if', skipTypeCheck: true),
            throwsA(isA<MontySyntaxError>()),
          );
        }
        final call = await _startCall(session);
        _position(call, '<python-input-$number>', 0, 3);
        await _complete(call);
      }
    },
  );

  test(
    'future position identifies the main blocked await',
    () async {
      final session = await protoBoundedSession();
      final call =
          await session.feedStart('x = 1\nawait f()') as FunctionSnapshot;
      final wait = await call.resume(const ExternalFuture()) as FutureSnapshot;
      _position(wait, '<python-input-0>', 6, 15);
      expect(
        (await wait.resume({
                  call.callId: const ExternalReturnValue(MontyInt(42)),
                })
                as MontyComplete)
            .output,
        const MontyInt(42),
      );
    },
  );
}
