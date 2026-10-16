import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 8) {
    throw ArgumentError(
      'expected cache, URL, file, bytes, digest, archive, archive bytes, '
      'archive digest',
    );
  }
  final artifact = WorkerArtifact(
    file: arguments[2],
    bytes: int.parse(arguments[3]),
    sha256: arguments[4],
    archive: WorkerArchive(
      name: arguments[5],
      bytes: int.parse(arguments[6]),
      sha256: arguments[7],
    ),
  );
  await installWorker(
    WorkerInstallRequest(
      artifact: artifact,
      cacheRoot: arguments[0],
      archiveUrl: Uri.parse(arguments[1]),
    ),
  );
}
