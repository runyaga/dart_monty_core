// Shared setup for the worker-channel tests: how to launch the fake and the
// real worker, and the per-test check that no worker process outlives its
// test.
import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

/// The fake worker running [scenario] (see fake_worker.dart).
WorkerExecutable fakeWorker(String scenario) => WorkerExecutable(
  Platform.resolvedExecutable,
  args: [
    File('test/integration/worker/fake_worker.dart').absolute.path,
    scenario,
  ],
);

/// The worker built by tool/build_worker.sh, or in CI the downloaded
/// artefact placed at the same path.
///
/// Throws, failing the test rather than skipping it, when there is none: a
/// smoke test that skips is a green that checked nothing. The StateError
/// names the path tried and the command that builds it.
Future<WorkerLaunch> realWorker() => locateWorker(
  cache: WorkerCacheSource(manifest: WorkerManifest(targets: {})),
);

/// Registers a tearDown that fails the test if any worker process is still
/// running once the test is over, after killing it so it cannot leak into
/// the next test.
///
/// Dart has no kill-on-drop, so this is what keeps a forgotten `close` from
/// passing silently.
void expectNoWorkersLeftAfterEachTest() {
  tearDown(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (ProcessChannel.live.isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final leaked = ProcessChannel.live.toList();
    if (leaked.isEmpty) return;
    final pids = [for (final channel in leaked) channel.pid];
    for (final channel in leaked) {
      channel.kill();
    }
    await Future.wait([for (final channel in leaked) channel.exitCode]);
    fail('worker processes left running after the test: $pids');
  });
}
