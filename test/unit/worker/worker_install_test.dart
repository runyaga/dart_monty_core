@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

import '_worker_mirror.dart';

void main() {
  group('workerArchiveUrl', () {
    test('uses a template override before the manifest mirror', () {
      final artifact = _artifact();
      final manifest = WorkerManifest(
        version: 'v1.2.3',
        mirror: 'https://manifest.invalid/{archive}',
        targets: const {},
      );
      expect(
        workerArchiveUrl(
          manifest: manifest,
          target: 'linux-x64',
          artifact: artifact,
          mirrorOverride: 'https://override.invalid/{tag}/{target}/{archive}',
        ).toString(),
        'https://override.invalid/v1.2.3/linux-x64/worker.gz',
      );
    });

    test('uses tag and target under a base mirror', () {
      final artifact = _artifact();
      expect(
        workerArchiveUrl(
          manifest: WorkerManifest(version: 'v1', targets: const {}),
          target: 'linux-x64',
          artifact: artifact,
          mirrorOverride: 'file:///tmp/mirror',
        ).toString(),
        'file:///tmp/mirror/v1/linux-x64/worker.gz',
      );
    });

    test('rejects a tag template without a release version', () {
      expect(
        () => workerArchiveUrl(
          manifest: WorkerManifest(targets: const {}),
          target: 'linux-x64',
          artifact: _artifact(),
          mirrorOverride: 'https://mirror.invalid/{tag}/{archive}',
        ),
        throwsA(isA<WorkerInstallError>()),
      );
    });
  });

  test('maps hook platform spelling to manifest spelling', () {
    expect(hookWorkerHostKey('macOS', 'arm64'), 'macos-arm64');
    expect(hookWorkerHostKey('LINUX', 'x64'), 'linux-x64');
  });

  test('installs a verified worker from a file mirror', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    final installed = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    expect(installed.downloaded, isTrue);
    await verifyWorkerFile(
      File(workerCacheFile(cache.path, mirror.artifact)),
      mirror.artifact,
    );
  });

  test('installs a verified worker from a loopback HTTP mirror', () async {
    final mirror = await WorkerMirror.create();
    final server = await WorkerHttpMirror.start(mirror.archive);
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await server.close();
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    final installed = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: server.url,
      ),
    );
    expect(installed.downloaded, isTrue);
    expect(server.requests, 1);
    await verifyWorkerFile(File(installed.path), mirror.artifact);
    expect(_temporaryEntries(cache), isEmpty);
  });

  test('keeps a valid warm entry without fetching or rewriting it', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    final first = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    final file = File(first.path);
    final before = file.statSync();
    final second = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
        fetcher: (_) => throw StateError('warm entry fetched'),
      ),
    );
    expect(second.alreadyInstalled, isTrue);
    expect(file.statSync().modified, before.modified);
  });

  test('uses a valid cache entry while the mirror is unavailable', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: Uri.parse('https://unavailable.invalid/worker.gz'),
        fetcher: (_) => throw StateError('mirror was contacted'),
      ),
    );
    expect(result.alreadyInstalled, isTrue);
  });

  test(
    'rejects a wrong archive without creating a final or staging entry',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      final incorrect = _withArchiveDigest(mirror.artifact, 'a' * 64);
      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: incorrect,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
          ),
        ),
        throwsA(isA<WorkerInstallError>()),
      );
      expect(
        Directory(workerCacheDir(cache.path, incorrect)).existsSync(),
        isFalse,
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );

  test('rejects HTTP failure and disallowed mirror schemes', () async {
    final mirror = await WorkerMirror.create();
    final server = await WorkerHttpMirror.start(
      mirror.archive,
      status: HttpStatus.notFound,
    );
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await server.close();
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: server.url,
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: Uri.parse('ftp://mirror.invalid/worker.gz'),
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
  });

  test(
    'sweeps dead and old staging while retaining a live fresh directory',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final old = Directory('${cache.path}/.staging-$pid-old')..createSync();
      if (!Platform.isWindows) {
        await Process.run('touch', ['-t', '200001010000', old.path]);
      }
      final dead = Directory('${cache.path}/.staging-999999999-dead')
        ..createSync();
      final live = Directory('${cache.path}/.staging-$pid-live')..createSync();
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      await installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
        ),
      );
      if (!Platform.isWindows) expect(old.existsSync(), isFalse);
      expect(dead.existsSync(), isFalse);
      expect(live.existsSync(), isTrue);
    },
  );

  test('breaks a stale lock and times out on a live lock', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    final lock = Directory(
      '${cache.path}/.lock-${mirror.artifact.archive?.sha256}',
    )..createSync();
    File('${lock.path}/owner').writeAsStringSync('999999999');
    await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    await Directory(
      '${cache.path}/.lock-${mirror.artifact.archive?.sha256}',
    ).create();
    final live = Directory(
      '${cache.path}/.lock-${mirror.artifact.archive?.sha256}',
    );
    File('${live.path}/owner').writeAsStringSync('$pid');
    final different = _withDigest(mirror.artifact, 'b' * 64);
    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: different,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          lockWait: const Duration(milliseconds: 100),
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
  });

  test(
    'concurrent cold installers download the loopback archive once',
    () async {
      final mirror = await WorkerMirror.create();
      final server = await WorkerHttpMirror.start(mirror.archive);
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await server.close();
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      await Future.wait([
        for (var index = 0; index < 4; index++)
          Isolate.run(
            _isolateInstall(mirror.artifact, cache.path, server.url),
          ),
      ]);
      expect(server.requests, 1);
      await verifyWorkerFile(
        File(workerCacheFile(cache.path, mirror.artifact)),
        mirror.artifact,
      );
    },
  );

  test(
    'copies only a verified library into a hook-style output path',
    () async {
      final mirror = await WorkerMirror.create();
      final output = await Directory.systemTemp.createTemp('worker_output_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await output.delete(recursive: true);
      });
      final destination = File('${output.path}/library.dylib');
      await copyVerifiedLibrary(
        source: mirror.archive,
        destination: destination,
        artifact: WorkerArtifact(
          file: 'library.dylib',
          bytes: await mirror.archive.length(),
          sha256: sha256.convert(await mirror.archive.readAsBytes()).toString(),
        ),
      );
      expect(destination.existsSync(), isTrue);
    },
  );
}

WorkerArtifact _artifact() => const WorkerArtifact(
  file: 'worker',
  bytes: 1,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  archive: WorkerArchive(
    name: 'worker.gz',
    bytes: 1,
    sha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  ),
);

WorkerArtifact _withArchiveDigest(WorkerArtifact artifact, String digest) =>
    WorkerArtifact(
      file: artifact.file,
      bytes: artifact.bytes,
      sha256: artifact.sha256,
      archive: WorkerArchive(
        name: artifact.archive?.name ?? 'worker.gz',
        bytes: artifact.archive?.bytes ?? 1,
        sha256: digest,
      ),
    );

WorkerArtifact _withDigest(WorkerArtifact artifact, String digest) =>
    WorkerArtifact(
      file: artifact.file,
      bytes: artifact.bytes,
      sha256: digest,
      archive: artifact.archive,
    );

List<FileSystemEntity> _temporaryEntries(Directory directory) => directory
    .listSync()
    .where(
      (entry) => entry.path.split(Platform.pathSeparator).last.startsWith('.'),
    )
    .toList();

Future<WorkerInstall> Function() _isolateInstall(
  WorkerArtifact artifact,
  String cacheRoot,
  Uri archiveUrl,
) =>
    () => installWorker(
      WorkerInstallRequest(
        artifact: artifact,
        cacheRoot: cacheRoot,
        archiveUrl: archiveUrl,
      ),
    );
