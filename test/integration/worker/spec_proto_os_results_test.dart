// Worker-generated OS refusal messages and immediate-result future handling.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

void _declines() {
  test('declined paths normalize and rename reports the source', () async {
    final session = await protoRealSession();
    for (final (code, path) in [
      ('open("/a//b/../c/./")', '/a/c'),
      ('open("")', ''),
      ('from pathlib import Path\nPath("/a//b/../c").rename("/other")', '/a/c'),
    ]) {
      await expectLater(
        session.feedRun(
          code,
          os: (_, _, _) => throw const OsCallNotHandledException(),
        ),
        throwsA(protoRuntime('PermissionError', "Permission denied: '$path'")),
      );
    }
    await expectLater(
      session.feedRun(
        'import os\nos.getenv("X")',
        os: (_, _, _) => throw const OsCallNotHandledException(),
      ),
      throwsA(
        protoRuntime(
          'RuntimeError',
          "'os.getenv' is not supported in this environment",
        ),
      ),
    );
    expect(await session.feedRun('42'), const MontyInt(42));
  });
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _declines();
  for (final (name, code) in [
    ('os.chdir', 'import os\nos.chdir("/x")'),
    ('os.listdir', 'import os\nos.listdir("/x")'),
    ('Path.iterdir', 'from pathlib import Path\nlist(Path("/x").iterdir())'),
    ('open', 'open("/x")'),
    ('time.sleep', 'import time\ntime.sleep(1)'),
  ]) {
    test(
      '$name refuses a manual future '
      'and consumes the snapshot',
      () async {
        final session = await protoRealSession(
          osPolicy: const OsPolicy(sleep: 'call_host'),
        );
        final snapshot = await session.feedStart(code) as FunctionSnapshot;
        final operation = switch (name) {
          'os.chdir' => 'Path.stat',
          'os.listdir' => 'Path.iterdir',
          _ => name,
        };
        expect(snapshot.functionName, operation);
        await expectLater(
          snapshot.resume(const ExternalFuture()),
          throwsA(
            protoRuntime(
              'RuntimeError',
              '$name cannot be answered with a future',
            ),
          ),
        );
        expect(
          () => snapshot.resume(const ExternalReturnValue(MontyNone())),
          throwsStateError,
        );
        // An independently registered future must be the only pending call.
        final next = await session.feedStart('await f()') as FunctionSnapshot;
        final pending =
            await next.resume(const ExternalFuture()) as FutureSnapshot;
        expect(pending.pendingCallIds, [next.callId]);
        expect(
          (await pending.resume({
                    next.callId: const ExternalReturnValue(MontyInt(42)),
                  })
                  as MontyComplete)
              .output,
          const MontyInt(42),
        );
      },
    );
  }
}
