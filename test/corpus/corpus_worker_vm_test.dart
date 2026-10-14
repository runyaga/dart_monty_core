// The upstream 1.1.0 corpus on the native worker, through the pool session,
// judged against the manifest in packages/monty_conformance; and crash
// recovery through one pool. Run by CI job `corpus-worker`:
//
//   dart test test/corpus -p vm --tags=corpus-worker
@Tags(['worker', 'corpus-worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/channel_factory.dart' as chf;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

import '../integration/worker/_worker_harness.dart';
import '_corpus_common.dart';
import '_crash_recovery.dart';

/// Equality of two 300,000-deep nested lists with the recursion limit lifted,
/// so the interpreter's native recursion overflows the worker's stack before
/// any Python limit stops it.
const _deepCompare =
    'x = []\nfor i in range(300000):\n    x = [x]\n'
    'y = []\nfor i in range(300000):\n    y = [y]\nx == y';

void main() {
  expectNoWorkersLeftAfterEachTest();

  corpusTests(
    CorpusTarget(
      label: 'native',
      profile: WorkerCorpusProfile.native,
      startPool: () => MontyPool.start(options: corpusPoolOptions),
    ),
  );

  crashRecoveryTests(
    'native',
    [
      CrashCase(
        name: 'the request deadline kills a spinning worker',
        code: 'while True:\n    pass',
        config: const SessionConfig(
          limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
        ),
        requestTimeout: const Duration(seconds: 1),
        check: (crash) {
          expect(crash.cause, CrashCause.killed);
          expect(crash.timedOut, isTrue);
        },
      ),
      CrashCase(
        name: 'a native stack overflow aborts the worker',
        code: _deepCompare,
        config: const SessionConfig(
          limits: ResourceLimits(
            maxMemory: 512 * 1024 * 1024,
            maxRecursionDepth: 100000000,
          ),
        ),
        check: (crash) {
          expect(crash.cause, CrashCause.vanished);
          expect(crash.stderrTail, contains('has overflowed its stack'));
        },
      ),
    ],
    (_) => chf.openChannel,
  );
}
