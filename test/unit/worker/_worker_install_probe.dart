// ignore_for_file: prefer-correct-test-file-name
// This subprocess entry point is invoked by worker_install_test.dart.

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';

Future<void> main(List<String> arguments) async {
  final cacheRoot = arguments.firstOrNull;
  final archiveUrl = arguments.elementAtOrNull(1);
  final file = arguments.elementAtOrNull(2);
  final bytes = arguments.elementAtOrNull(3);
  final digest = arguments.elementAtOrNull(4);
  final archive = arguments.elementAtOrNull(5);
  final archiveBytes = arguments.elementAtOrNull(6);
  final archiveDigest = arguments.elementAtOrNull(7);
  if (arguments.length != 8 ||
      cacheRoot == null ||
      archiveUrl == null ||
      file == null ||
      bytes == null ||
      digest == null ||
      archive == null ||
      archiveBytes == null ||
      archiveDigest == null) {
    throw ArgumentError(
      'expected cache, URL, file, bytes, digest, archive, archive bytes, '
      'archive digest',
    );
  }
  final artifact = WorkerArtifact(
    file: file,
    bytes: int.parse(bytes),
    sha256: digest,
    archive: WorkerArchive(
      name: archive,
      bytes: int.parse(archiveBytes),
      sha256: archiveDigest,
    ),
  );
  await installWorker(
    WorkerInstallRequest(
      artifact: artifact,
      cacheRoot: cacheRoot,
      archiveUrl: Uri.parse(archiveUrl),
    ),
  );
}
