import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';

final class WorkerMirror {
  WorkerMirror._(this.directory, this.artifact, this.archive, this.contents);

  final Directory directory;
  final WorkerArtifact artifact;
  final File archive;
  final Uint8List contents;

  Uri get fileUrl => archive.uri;

  static Future<WorkerMirror> create() async {
    final directory = await Directory.systemTemp.createTemp('worker_mirror_');
    final contents = Uint8List.fromList(utf8.encode('fake worker payload'));
    final archive = File('${directory.path}/worker.gz');
    await archive.writeAsBytes(gzip.encode(contents), flush: true);
    final archiveBytes = await archive.readAsBytes();
    final artifact = WorkerArtifact(
      file: 'dart_monty_worker',
      bytes: contents.length,
      sha256: sha256.convert(contents).toString(),
      archive: WorkerArchive(
        name: 'worker.gz',
        bytes: archiveBytes.length,
        sha256: sha256.convert(archiveBytes).toString(),
      ),
    );
    return WorkerMirror._(directory, artifact, archive, contents);
  }
}

/// Serves a worker archive over a loopback HTTP connection.
final class WorkerHttpMirror {
  WorkerHttpMirror._(this.server, this.archive, this.status, this.throttle);

  final HttpServer server;
  final File archive;
  final int status;
  final Duration? throttle;
  int requests = 0;

  Uri get url =>
      Uri.parse('http://${server.address.host}:${server.port}/worker.gz');

  static Future<WorkerHttpMirror> start(
    File archive, {
    int status = HttpStatus.ok,
    Duration? throttle,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mirror = WorkerHttpMirror._(server, archive, status, throttle);
    unawaited(mirror._serve());
    return mirror;
  }

  Future<void> close() => server.close(force: true);

  Future<void> _serve() async {
    await for (final request in server) {
      requests++;
      request.response.statusCode = status;
      if (status == HttpStatus.ok) {
        final bytes = await archive.readAsBytes();
        final delay = throttle;
        for (final byte in bytes) {
          request.response.add([byte]);
          if (delay != null) await Future<void>.delayed(delay);
        }
      }
      await request.response.close();
    }
  }
}
