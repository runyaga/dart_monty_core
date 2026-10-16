@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '_worker_mirror.dart';

void main() {
  _archiveUrlTests();
  _installationFailureTests();
  _platformTest();
  _fileMirrorTest();
  _httpMirrorTest();
  _warmEntryTest();
  _unavailableMirrorTest();
  _badArchiveTest();
  _httpFailureTest();
  _downloadLimitTests();
  _forbiddenRedirectTest();
  _loopbackRedirectTest();
  _tooManyRedirectsTest();
  _fetcherFailureTests();
  _publishWindowTest();
  _publishRenameRaceTest();
  _decompressionLimitTest();
  _stagingSweepTest();
  _staleLockTest();
  _ownerlessLockTest();
  _concurrentInstallTest();
  _lockRaceTests();
  _initializerFailureTests();
  _verifiedCopyTest();
  _artifactLockTest();
}

void _archiveUrlTests() {
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

    test('resolves a versionless template that does not use tag', () {
      expect(
        workerArchiveUrl(
          manifest: WorkerManifest(targets: const {}),
          target: 'linux-x64',
          artifact: _artifact(),
          mirrorOverride: 'https://mirror.invalid/{archive}',
        ).toString(),
        'https://mirror.invalid/worker.gz',
      );
    });

    test('uses the default mirror and normalizes a trailing slash', () {
      final artifact = _artifact();
      expect(
        workerArchiveUrl(
          manifest: WorkerManifest(version: 'v1', targets: const {}),
          target: 'linux-x64',
          artifact: artifact,
        ).toString(),
        'https://github.com/runyaga/dart_monty_core/releases/download/v1/'
        'worker.gz',
      );
      expect(
        workerArchiveUrl(
          manifest: WorkerManifest(version: 'v1', targets: const {}),
          target: 'linux-x64',
          artifact: artifact,
          mirrorOverride: 'https://mirror.invalid/releases/',
        ).toString(),
        'https://mirror.invalid/releases/v1/linux-x64/worker.gz',
      );
    });

    test('rejects an artifact without an archive', () {
      expect(
        () => workerArchiveUrl(
          manifest: WorkerManifest(targets: const {}),
          target: 'linux-x64',
          artifact: const WorkerArtifact(
            file: 'worker',
            bytes: 1,
            sha256: _aDigest,
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('has no archive'),
          ),
        ),
      );
    });
  });
  _traversalSegmentTests();
}

void _installationFailureTests() {
  test('reports a missing archive before touching the cache', () async {
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() => cache.delete(recursive: true));

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: const WorkerArtifact(
            file: 'worker',
            bytes: 1,
            sha256: _aDigest,
          ),
          cacheRoot: cache.path,
          archiveUrl: Uri.parse('file:///unused'),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('has no archive'),
        ),
      ),
    );
    expect(cache.listSync(), isEmpty);
  });

  test('wraps an unexpected installer failure and releases its lock', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: (stage) => stage == 'afterLock'
              ? Future<void>.error(StateError('stage exploded'))
              : Future.value(),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          allOf(contains('could not install'), contains('stage exploded')),
        ),
      ),
    );
    expect(_temporaryEntries(cache), isEmpty);
  });

  test('reports an unusable cache-root path', () async {
    final mirror = await WorkerMirror.create();
    final parent = await Directory.systemTemp.createTemp('worker_cache_');
    final rootFile = File('${parent.path}/not-a-directory')
      ..writeAsStringSync('file');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await parent.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: '${rootFile.path}/child',
          archiveUrl: mirror.fileUrl,
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('cache root'),
        ),
      ),
    );
  });

  test(
    'times out when an existing cache root cannot create either lock',
    () async {
      if (Platform.isWindows) return;
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      await Process.run('chmod', ['555', cache.path]);
      addTearDown(() async {
        await Process.run('chmod', ['755', cache.path]);
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
            lockWait: Duration.zero,
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('remained busy'),
          ),
        ),
      );
      await Process.run('chmod', ['755', cache.path]);
      expect(cache.listSync(), isEmpty);
    },
  );

  test('replaces a valid but non-executable cached worker', () async {
    if (Platform.isWindows) return;
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final directory = Directory(workerCacheDir(cache.path, mirror.artifact))
      ..createSync(recursive: true);
    final old = File('${directory.path}/${mirror.artifact.file}')
      ..writeAsBytesSync(mirror.contents);
    await Process.run('chmod', ['644', old.path]);
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    expect(result.alreadyInstalled, isFalse);
    expect(File(result.path).statSync().mode & 0x49, isNot(0));
  });

  test('replaces an unreadable cached worker', () async {
    if (Platform.isWindows) return;
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final directory = Directory(workerCacheDir(cache.path, mirror.artifact))
      ..createSync(recursive: true);
    final old = File('${directory.path}/${mirror.artifact.file}')
      ..writeAsBytesSync(mirror.contents);
    await Process.run('chmod', ['000', old.path]);
    addTearDown(() async {
      await Process.run('chmod', ['644', old.path]);
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    expect(result.downloaded, isTrue);
    await verifyWorkerFile(File(result.path), mirror.artifact);
  });

  test(
    'reports a worker that disappears before executable permissions',
    () async {
      if (Platform.isWindows) return;
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
            onStage: (stage) async {
              if (stage != 'beforeChmod') return;
              final staging = _onlyStaging(cache);
              await File('${staging.path}/${mirror.artifact.file}').delete();
            },
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('could not be made executable'),
          ),
        ),
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );

  test(
    'reports an unreadable archive stream without leaving staging',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: Uri.parse('https://mirror.invalid/worker.gz'),
            fetcher: (_) => Stream<List<int>>.error(StateError('read failed')),
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            allOf(contains('could not be read'), contains('read failed')),
          ),
        ),
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );

  test(
    'leaves staging when a concurrent permission change blocks cleanup',
    () async {
      if (Platform.isWindows) return;
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      late Directory staging;
      addTearDown(() async {
        if (staging.existsSync()) {
          await Process.run('chmod', ['755', staging.path]);
        }
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
            onStage: (stage) async {
              if (stage != 'beforeChmod') return;
              staging = _onlyStaging(cache);
              await File('${staging.path}/${mirror.artifact.file}').delete();
              await File('${staging.path}/blocked').writeAsString('blocked');
              await Process.run('chmod', ['555', staging.path]);
            },
          ),
        ),
        throwsA(isA<WorkerInstallError>()),
      );
      expect(staging.existsSync(), isTrue);
      await Process.run('chmod', ['755', staging.path]);
      await staging.delete(recursive: true);
      expect(_temporaryEntries(cache), isEmpty);
    },
  );

  test(
    'reports invalid gzip after accepting the declared archive bytes',
    () async {
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final bytes = [1, 2, 3, 4];
      final artifact = WorkerArtifact(
        file: 'worker',
        bytes: 1,
        sha256: _aDigest,
        archive: WorkerArchive(
          name: 'worker.gz',
          bytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      );
      addTearDown(() => cache.delete(recursive: true));

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: artifact,
            cacheRoot: cache.path,
            archiveUrl: Uri.parse('https://mirror.invalid/worker.gz'),
            fetcher: (_) => Stream.value(bytes),
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('not valid gzip'),
          ),
        ),
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );
}

void _traversalSegmentTests() {
  for (final mirror in [
    'https://mirror.invalid/{tag}/{target}/{archive}',
    'https://mirror.invalid',
  ]) {
    test('rejects traversal segments for $mirror', () {
      expect(
        () => workerArchiveUrl(
          manifest: WorkerManifest(version: '..', targets: const {}),
          target: '.',
          artifact: const WorkerArtifact(
            file: 'worker',
            bytes: 1,
            sha256: _aDigest,
            archive: WorkerArchive(
              name: '..',
              bytes: 1,
              sha256: _bDigest,
            ),
          ),
          mirrorOverride: mirror,
        ),
        throwsA(isA<WorkerInstallError>()),
      );
    });
  }
}

void _platformTest() {
  test('maps hook platform spelling to manifest spelling', () {
    expect(hookWorkerHostKey('macOS', 'arm64'), 'macos-arm64');
    expect(hookWorkerHostKey('LINUX', 'x64'), 'linux-x64');
  });
}

void _fileMirrorTest() {
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
}

void _httpMirrorTest() {
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
}

void _warmEntryTest() {
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
}

void _unavailableMirrorTest() {
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
}

void _badArchiveTest() {
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
}

void _httpFailureTest() {
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
    final install = installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: server.url,
      ),
    );
    final installError = throwsA(isA<WorkerInstallError>());
    await expectLater(install, installError);
    final disallowedInstall = installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: Uri.parse('ftp://mirror.invalid/worker.gz'),
      ),
    );
    await expectLater(disallowedInstall, installError);
  });
}

void _downloadLimitTests() {
  test('rejects an overrun archive stream promptly and cancels it', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final cancelled = Completer<void>();
    final controller = StreamController<List<int>>(
      onCancel: cancelled.complete,
    );
    final archive = await mirror.archive.readAsBytes();
    final install = installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: Uri.parse('https://mirror.invalid/worker.gz'),
        fetcher: (_) => controller.stream,
      ),
    );
    addTearDown(() async {
      await controller.close();
      await _settle(install);
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    controller
      ..add(archive)
      ..add([0]);

    await expectLater(
      install.timeout(const Duration(seconds: 3)),
      throwsA(isA<WorkerInstallError>()),
    );
    await cancelled.future.timeout(const Duration(seconds: 3));
    expect(
      Directory(workerCacheDir(cache.path, mirror.artifact)).existsSync(),
      isFalse,
    );
    expect(_temporaryEntries(cache), isEmpty);
  });

  test(
    'rejects a truncated archive stream without temporary entries',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      final archive = await mirror.archive.readAsBytes();

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: Uri.parse('https://mirror.invalid/worker.gz'),
            fetcher: (_) =>
                Stream.value(archive.sublist(0, archive.length - 1)),
          ),
        ),
        throwsA(isA<WorkerInstallError>()),
      );
      expect(
        Directory(workerCacheDir(cache.path, mirror.artifact)).existsSync(),
        isFalse,
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );
}

void _forbiddenRedirectTest() {
  test('rejects a redirect to a disallowed host before connecting', () async {
    final mirror = await WorkerMirror.create();
    final server = await _RedirectServer.start(mirror.archive, const {
      '/forbidden': 'http://mirror.example/x',
    });
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
          archiveUrl: server.url('/forbidden'),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('redirect URL'),
        ),
      ),
    );
    expect(server.requests, 1);
  });
}

void _loopbackRedirectTest() {
  test('follows a permitted loopback redirect chain', () async {
    final mirror = await WorkerMirror.create();
    final server = await _RedirectServer.start(mirror.archive, const {
      '/first': '/second',
      '/second': '/worker.gz',
    });
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await server.close();
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    final redirected = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: server.url('/first'),
      ),
    );
    expect(redirected.downloaded, isTrue);
  });
}

void _tooManyRedirectsTest() {
  test('rejects a redirect chain longer than five hops', () async {
    final mirror = await WorkerMirror.create();
    final server = await _RedirectServer.start(mirror.archive, const {
      '/loop/0': '/loop/1',
      '/loop/1': '/loop/2',
      '/loop/2': '/loop/3',
      '/loop/3': '/loop/4',
      '/loop/4': '/loop/5',
      '/loop/5': '/loop/6',
    });
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
          archiveUrl: server.url('/loop/0'),
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
  });
}

void _fetcherFailureTests() {
  test('reports a redirect that omits Location', () async {
    final mirror = await WorkerMirror.create();
    final server = await WorkerHttpMirror.start(
      mirror.archive,
      status: HttpStatus.found,
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
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('without Location'),
        ),
      ),
    );
    expect(_temporaryEntries(cache), isEmpty);
  });

  test('rejects non-loopback HTTP before opening a connection', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: Uri.parse('http://mirror.invalid/worker.gz'),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('unsupported scheme or insecure host'),
        ),
      ),
    );
  });

  test('wraps a loopback connection failure with the archive URL', () async {
    final mirror = await WorkerMirror.create();
    final reserved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = Uri.parse(
      'http://${reserved.address.host}:${reserved.port}/worker.gz',
    );
    await reserved.close();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: url,
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          allOf(contains('could not be downloaded'), contains(url.toString())),
        ),
      ),
    );
  });
}

void _publishWindowTest() {
  test('preserves a valid entry published during the publish window', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });
    late File concurrentFile;
    late String inode;
    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
        onStage: (stage) async {
          if (stage != 'beforePublish') return;
          final directory = Directory(
            workerCacheDir(cache.path, mirror.artifact),
          );
          await directory.create(recursive: true);
          concurrentFile = File(workerCacheFile(cache.path, mirror.artifact));
          await concurrentFile.writeAsBytes(mirror.contents, flush: true);
          if (!Platform.isWindows) {
            await Process.run('chmod', ['755', concurrentFile.path]);
          }
          inode = await _inode(concurrentFile);
        },
      ),
    );
    expect(result.alreadyInstalled, isTrue);
    await verifyWorkerFile(concurrentFile, mirror.artifact);
    expect(await _inode(concurrentFile), inode);
  });
}

void _publishRenameRaceTest() {
  test('keeps a verified winner when publish rename loses its race', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
        onStage: (stage) async {
          if (stage != 'beforePublishRename') return;
          final winner = Directory(workerCacheDir(cache.path, mirror.artifact));
          await winner.create();
          final file = File('${winner.path}/${mirror.artifact.file}');
          await file.writeAsBytes(mirror.contents, flush: true);
          if (!Platform.isWindows) {
            await Process.run('chmod', ['755', file.path]);
          }
        },
      ),
    );
    expect(result.alreadyInstalled, isTrue);
    await verifyWorkerFile(File(result.path), mirror.artifact);
    expect(_temporaryEntries(cache), isEmpty);
  });
}

void _decompressionLimitTest() {
  test(
    'rejects an archive that expands beyond its declared worker size',
    () async {
      final directory = await Directory.systemTemp.createTemp('worker_mirror_');
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      final contents = List.filled(30, 7);
      final archive = gzip.encode(contents);
      final archiveFile = File('${directory.path}/worker.gz');
      await archiveFile.writeAsBytes(archive, flush: true);
      final artifact = WorkerArtifact(
        file: 'dart_monty_worker',
        bytes: 10,
        sha256: sha256.convert(contents.take(10).toList()).toString(),
        archive: WorkerArchive(
          name: 'worker.gz',
          bytes: archive.length,
          sha256: sha256.convert(archive).toString(),
        ),
      );
      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: artifact,
            cacheRoot: cache.path,
            archiveUrl: archiveFile.uri,
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('exceeds'),
          ),
        ),
      );
      expect(
        Directory(workerCacheDir(cache.path, artifact)).existsSync(),
        isFalse,
      );
      expect(_temporaryEntries(cache), isEmpty);
    },
  );
}

void _stagingSweepTest() {
  test(
    'retains a live old staging directory and sweeps dead staging',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final old = Directory('${cache.path}/.staging-$pid-old')..createSync();
      File('${old.path}/owner').writeAsStringSync('$pid staging-token');
      final dead = Directory('${cache.path}/.staging-999999999-dead')
        ..createSync();
      File('${dead.path}/owner').writeAsStringSync('999999999 dead-token');
      final live = Directory('${cache.path}/.staging-$pid-live')..createSync();
      File('${live.path}/owner').writeAsStringSync('$pid live-token');
      final staleLock = Directory('${cache.path}/.stale-lock-999999999-old')
        ..createSync();
      await Future.wait([old, dead, live, staleLock].map(_backdate));
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
      expect(old.existsSync(), isTrue);
      expect(dead.existsSync(), isFalse);
      expect(staleLock.existsSync(), isFalse);
      expect(live.existsSync(), isTrue);
    },
  );
}

void _staleLockTest() {
  test(
    'breaks a dead old lock and retains a live old lock',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      final lockPath = '${cache.path}/.lock-${mirror.artifact.sha256}';
      final lock = Directory(lockPath)..createSync();
      File('${lock.path}/owner').writeAsStringSync('999999999 dead-token');
      await _backdate(lock);
      await installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
        ),
      );
      await Directory(lockPath).create();
      final live = Directory(lockPath);
      File('${live.path}/owner').writeAsStringSync('$pid live-token');
      await _backdate(live);
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
    },
  );

  test('reclaims an abandoned breaker before removing a dead lock', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final digest = mirror.artifact.sha256;
    final lock = Directory('${cache.path}/.lock-$digest')..createSync();
    final breaker = Directory('${cache.path}/.break-$digest')..createSync();
    File('${lock.path}/owner').writeAsStringSync('999999999 dead-lock');
    await _backdate(lock);
    await _backdate(breaker);
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    expect(result.downloaded, isTrue);
    expect(breaker.existsSync(), isFalse);
    expect(lock.existsSync(), isFalse);
  });

  test('continues when another installer removes a stale lock first', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}')
      ..createSync();
    File('${lock.path}/owner').writeAsStringSync('999999999 dead-lock');
    await _backdate(lock);
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final result = await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
        onStage: (stage) async {
          if (stage == 'beforeMoveStaleLock') {
            await lock.delete(recursive: true);
          }
        },
      ),
    );
    expect(result.downloaded, isTrue);
    expect(lock.existsSync(), isFalse);
  });
}

void _ownerlessLockTest() {
  test('retains a fresh ownerless lock but breaks an old one', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}')
      ..createSync();
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          lockWait: const Duration(milliseconds: 100),
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
    expect(lock.existsSync(), isTrue);

    await _backdate(lock);
    await installWorker(
      WorkerInstallRequest(
        artifact: mirror.artifact,
        cacheRoot: cache.path,
        archiveUrl: mirror.fileUrl,
      ),
    );
    expect(Directory(lock.path).existsSync(), isFalse);
  });
}

void _concurrentInstallTest() {
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
}

void _lockRaceTests() {
  _replacementLockReleaseTest();
  _lostLockOwnershipTest();
  _deadLockContenderTest();
  _liveLockContenderTest();
}

void _lostLockOwnershipTest() {
  test(
    'reports a lock whose owner changes while it is being acquired',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
            onStage: (stage) async {
              if (stage != 'afterLockOwner') return;
              await File(
                '${lock.path}/owner',
              ).writeAsString('$pid replacement');
            },
          ),
        ),
        throwsA(
          isA<WorkerInstallError>().having(
            (error) => error.message,
            'message',
            contains('could not retain its installation lock'),
          ),
        ),
      );
      expect(File('${lock.path}/owner').readAsStringSync(), '$pid replacement');
    },
  );
}

void _replacementLockReleaseTest() {
  test(
    'release leaves a replacement lock owned by another acquisition',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });
      final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}');

      await installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: (stage) async {
            if (stage != 'afterLock') return;
            await lock.delete(recursive: true);
            await lock.create();
            await File('${lock.path}/owner').writeAsString('$pid replacement');
          },
        ),
      );

      expect(lock.existsSync(), isTrue);
      expect(File('${lock.path}/owner').readAsStringSync(), '$pid replacement');
    },
  );
}

void _deadLockContenderTest() {
  test(
    'two contenders replace one dead lock without losing the final entry',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}')
        ..createSync();
      File('${lock.path}/owner').writeAsStringSync('999999999 dead-token');
      await _backdate(lock);
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      final server = await WorkerHttpMirror.start(mirror.archive);
      addTearDown(server.close);
      final installed = await Future.wait([
        for (var index = 0; index < 6; index++)
          Isolate.run(
            _isolateInstall(mirror.artifact, cache.path, server.url),
          ),
      ]);

      await verifyWorkerFile(
        File(workerCacheFile(cache.path, mirror.artifact)),
        mirror.artifact,
      );
      expect(lock.existsSync(), isFalse);
      expect(server.requests, 1);
      expect(installed.where((result) => result.downloaded), hasLength(1));
    },
  );
}

void _liveLockContenderTest() {
  test('contenders retain an old lock owned by a live process', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}')
      ..createSync();
    File('${lock.path}/owner').writeAsStringSync('$pid live-token');
    await _backdate(lock);
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    final results = await Future.wait([
      for (var index = 0; index < 6; index++)
        Isolate.run(
          _isolateInstallResult(
            mirror.artifact,
            cache.path,
            mirror.fileUrl,
          ),
        ),
    ]);

    expect(results, everyElement(isFalse));
    expect(lock.existsSync(), isTrue);
    expect(File('${lock.path}/owner').readAsStringSync(), '$pid live-token');
  });
}

void _initializerFailureTests() {
  _lockOwnerMetadataFailureTest();
  _otherOwnerMetadataFailureTest();
  _stagingOwnerMetadataFailureTest();
  _stagingOwnerCollisionTest();
  _stagingCreationFailureTest();
}

void _lockOwnerMetadataFailureTest() {
  test('removes a lock when writing its owner metadata fails', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: _failOwnerMetadata('beforeLockOwner'),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains(cache.path),
        ),
      ),
    );
    expect(_temporaryEntries(cache), isEmpty);
  });
}

void _otherOwnerMetadataFailureTest() {
  test(
    'leaves a lock acquired by another owner after metadata failure',
    () async {
      final mirror = await WorkerMirror.create();
      final cache = await Directory.systemTemp.createTemp('worker_cache_');
      final lock = Directory('${cache.path}/.lock-${mirror.artifact.sha256}');
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await cache.delete(recursive: true);
      });

      await expectLater(
        installWorker(
          WorkerInstallRequest(
            artifact: mirror.artifact,
            cacheRoot: cache.path,
            archiveUrl: mirror.fileUrl,
            onStage: (stage) async {
              if (stage != 'beforeLockOwner') return;
              await File('${lock.path}/owner').writeAsString('999999999 other');
              throw StateError('owner write lost race');
            },
          ),
        ),
        throwsA(isA<WorkerInstallError>()),
      );
      expect(File('${lock.path}/owner').readAsStringSync(), '999999999 other');
    },
  );
}

void _stagingOwnerMetadataFailureTest() {
  test('removes staging when writing its owner metadata fails', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: _failOwnerMetadata('beforeStagingOwner'),
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains(cache.path),
        ),
      ),
    );
    expect(_temporaryEntries(cache), isEmpty);
  });
}

void _stagingOwnerCollisionTest() {
  test('reports staging owner metadata created by another installer', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: (stage) async {
            if (stage != 'beforeStagingOwner') return;
            final staging = _onlyStaging(cache);
            await File('${staging.path}/owner').writeAsString('other owner');
          },
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('already contains staging owner metadata'),
        ),
      ),
    );
    expect(_temporaryEntries(cache), isEmpty);
  });
}

void _stagingCreationFailureTest() {
  test('reports a staging directory that cannot be created', () async {
    if (Platform.isWindows) return;
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    addTearDown(() async {
      await Process.run('chmod', ['755', cache.path]);
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await expectLater(
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
          onStage: (stage) async {
            if (stage == 'afterLock') {
              await Process.run('chmod', ['555', cache.path]);
            }
          },
        ),
      ),
      throwsA(
        isA<WorkerInstallError>().having(
          (error) => error.message,
          'message',
          contains('could not create staging'),
        ),
      ),
    );
    await Process.run('chmod', ['755', cache.path]);
    expect(_temporaryEntries(cache), isNotEmpty);
  });
}

void _verifiedCopyTest() {
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

  test('keeps a valid destination when source verification fails', () async {
    final output = await Directory.systemTemp.createTemp('worker_output_');
    final destination = File('${output.path}/library.dylib')
      ..writeAsBytesSync([1, 2, 3]);
    final readDestination = destination.readAsBytes;
    final before = await readDestination();
    final source = File('${output.path}/invalid')..writeAsBytesSync([4]);
    addTearDown(() => output.delete(recursive: true));

    await expectLater(
      copyVerifiedLibrary(
        source: source,
        destination: destination,
        artifact: const WorkerArtifact(
          file: 'library.dylib',
          bytes: 2,
          sha256: _aDigest,
        ),
      ),
      throwsA(isA<WorkerInstallError>()),
    );
    final after = await readDestination();
    expect(after, before);
  });

  test(
    'removes the temporary library copy after a destination collision',
    () async {
      final mirror = await WorkerMirror.create();
      final output = await Directory.systemTemp.createTemp('worker_output_');
      final destination = Directory('${output.path}/library.dylib')
        ..createSync();
      addTearDown(() async {
        await mirror.directory.delete(recursive: true);
        await output.delete(recursive: true);
      });

      await expectLater(
        copyVerifiedLibrary(
          source: mirror.archive,
          destination: File(destination.path),
          artifact: WorkerArtifact(
            file: 'library.dylib',
            bytes: await mirror.archive.length(),
            sha256: sha256
                .convert(await mirror.archive.readAsBytes())
                .toString(),
          ),
        ),
        throwsA(isA<WorkerInstallError>()),
      );
      expect(
        output.listSync().where(
          (entry) => path.basename(entry.path).startsWith('library.dylib.tmp-'),
        ),
        isEmpty,
      );
    },
  );
}

void _artifactLockTest() {
  test('uses one artifact lock for distinct gzip encodings', () async {
    final mirror = await WorkerMirror.create();
    final cache = await Directory.systemTemp.createTemp('worker_cache_');
    final alternate = File('${mirror.directory.path}/alternate.gz');
    final bytes = await mirror.archive.readAsBytes();
    final headerByte = bytes.elementAtOrNull(4) ?? 0;
    bytes[4] = (headerByte + 1) % 255;
    await alternate.writeAsBytes(bytes, flush: true);
    final alternateArtifact = WorkerArtifact(
      file: mirror.artifact.file,
      bytes: mirror.artifact.bytes,
      sha256: mirror.artifact.sha256,
      archive: WorkerArchive(
        name: 'alternate.gz',
        bytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ),
    );
    final invalid = Directory(workerCacheDir(cache.path, mirror.artifact))
      ..createSync(recursive: true);
    File('${invalid.path}/${mirror.artifact.file}').writeAsStringSync('bad');
    addTearDown(() async {
      await mirror.directory.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    await Future.wait([
      installWorker(
        WorkerInstallRequest(
          artifact: mirror.artifact,
          cacheRoot: cache.path,
          archiveUrl: mirror.fileUrl,
        ),
      ),
      installWorker(
        WorkerInstallRequest(
          artifact: alternateArtifact,
          cacheRoot: cache.path,
          archiveUrl: alternate.uri,
        ),
      ),
    ]);
    await verifyWorkerFile(
      File(workerCacheFile(cache.path, mirror.artifact)),
      mirror.artifact,
    );
  });
}

const _aDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

WorkerArtifact _artifact() => const WorkerArtifact(
  file: 'worker',
  bytes: 1,
  sha256: _aDigest,
  archive: WorkerArchive(
    name: 'worker.gz',
    bytes: 1,
    sha256: _bDigest,
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
    .where((entry) => path.basename(entry.path).startsWith('.'))
    .toList();

Directory _onlyStaging(Directory cache) {
  final staging = cache.listSync().whereType<Directory>().singleWhereOrNull(
    (entry) => path.basename(entry.path).startsWith('.staging-'),
  );
  if (staging == null) throw StateError('expected exactly one staging entry');

  return staging;
}

Future<String> _inode(File file) async {
  if (Platform.isWindows) return file.path;
  final arguments = Platform.isMacOS
      ? ['-f', '%i', file.path]
      : ['-c', '%i', file.path];
  final result = await Process.run('stat', arguments);

  return result.stdout.toString().trim();
}

Future<void> _backdate(Directory directory) async {
  final result = Platform.isWindows
      ? await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          _windowsBackdateCommand(directory.path),
        ])
      : await Process.run('touch', ['-t', '200001010000', directory.path]);
  expect(result.exitCode, 0);
}

String _windowsBackdateCommand(String path) => [
  "(Get-Item -LiteralPath '$path').LastWriteTime=",
  "Get-Date '2000-01-01'",
].join();

final class _RedirectServer {
  _RedirectServer._(this.server, this.archive, this.redirects);

  final HttpServer server;
  final File archive;
  final Map<String, String> redirects;
  int requests = 0;

  Uri url(String path) =>
      Uri.parse('http://${server.address.host}:${server.port}$path');

  static Future<_RedirectServer> start(
    File archive,
    Map<String, String> redirects,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _RedirectServer._(server, archive, redirects);
    unawaited(result._serve());

    return result;
  }

  Future<void> close() => server.close(force: true);

  Future<void> _serve() async {
    await for (final request in server) {
      requests++;
      final location = redirects[request.uri.path];
      if (location != null) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, location);
      } else {
        request.response.add(await archive.readAsBytes());
      }
      await request.response.close();
    }
  }
}

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

Future<bool> Function() _isolateInstallResult(
  WorkerArtifact artifact,
  String cacheRoot,
  Uri archiveUrl,
) => () async {
  try {
    await installWorker(
      WorkerInstallRequest(
        artifact: artifact,
        cacheRoot: cacheRoot,
        archiveUrl: archiveUrl,
        lockWait: const Duration(milliseconds: 300),
      ),
    );

    return true;
  } on WorkerInstallError {
    return false;
  }
};

Future<void> Function(String) _failOwnerMetadata(String target) =>
    (stage) => stage == target
    ? Future<void>.error(StateError('injected metadata failure'))
    : Future.value();

/// Waits for [install] to finish, whether it succeeds or throws.
Future<void> _settle(Future<Object?> install) async {
  try {
    await install;
  } on WorkerInstallError {
    return;
  }
}
