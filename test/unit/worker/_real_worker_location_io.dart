import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';

/// The contributor-built worker, not the published-worker cache.
Future<String?> realWorkerLocation() async {
  final worker = await locateWorker(
    cache: WorkerCacheSource(manifest: WorkerManifest(targets: {})),
  );

  return (worker as WorkerExecutable).path;
}
