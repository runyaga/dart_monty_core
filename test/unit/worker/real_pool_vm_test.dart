// A pool of real workers in the default unit run. CI's `test` job and the
// gate's unit_tests stage provide the worker executable first (the
// worker-rust artefact, or tool/build_worker.sh), so an untagged test may
// start one.
@TestOn('vm')
@Tags(['vm-only'])
library;

import 'package:dart_monty_core/dart_monty_core.dart' show MontyInt;
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../integration/worker/_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();

  test('a pool starts a real worker and runs Python on it', () async {
    final value = await MontyPool.withPool(
      (pool) async {
        expect(ProcessChannel.live, hasLength(1));

        return pool.withSession(
          (s) => s.feedRun('6 * 7'),
          options: const SessionConfig(
            limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
          ),
        );
      },
      options: const PoolOptions(maxProcesses: 1),
    );
    expect(value, const MontyInt(42));
  });
}
