@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('workerCacheRoot', () {
    test('uses the real host operating system and environment by default', () {
      expect(
        workerCacheRoot(),
        workerCacheRoot(
          environment: Platform.environment,
          operatingSystem: Platform.operatingSystem,
        ),
      );
    });

    test('uses the macOS HOME cache directory', () {
      expect(
        workerCacheRoot(
          environment: {'HOME': '/srv/ada'},
          operatingSystem: 'macos',
        ),
        '/srv/ada/Library/Caches/dart_monty',
      );
    });

    test('uses the Linux HOME cache directory', () {
      expect(
        workerCacheRoot(
          environment: {'HOME': '/home/ada'},
          operatingSystem: 'linux',
        ),
        '/home/ada/.cache/dart_monty',
      );
    });

    test('uses the Windows LOCALAPPDATA cache directory', () {
      expect(
        workerCacheRoot(
          environment: {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
          operatingSystem: 'windows',
        ),
        r'C:\Users\Ada\AppData\Local\dart_monty\Cache',
      );
    });

    test('falls back to USERPROFILE when LOCALAPPDATA is absent', () {
      expect(
        workerCacheRoot(
          environment: {'USERPROFILE': r'C:\Users\Ada'},
          operatingSystem: 'windows',
        ),
        r'C:\Users\Ada\AppData\Local\dart_monty\Cache',
      );
    });

    test('prefers LOCALAPPDATA over USERPROFILE when both are set', () {
      expect(
        workerCacheRoot(
          environment: {
            'LOCALAPPDATA': r'D:\cache',
            'USERPROFILE': r'C:\Users\Ada',
          },
          operatingSystem: 'windows',
        ),
        r'D:\cache\dart_monty\Cache',
      );
    });

    for (final localAppData in [r'\srv\cache', '/srv/cache']) {
      test('falls back to USERPROFILE for root-relative '
          'LOCALAPPDATA $localAppData', () {
        expect(
          workerCacheRoot(
            environment: {
              'LOCALAPPDATA': localAppData,
              'USERPROFILE': r'C:\Users\Ada',
            },
            operatingSystem: 'windows',
          ),
          r'C:\Users\Ada\AppData\Local\dart_monty\Cache',
        );
      });

      test('rejects root-relative Windows LOCALAPPDATA $localAppData '
          'with no USERPROFILE', () {
        expect(
          () => workerCacheRoot(
            environment: {'LOCALAPPDATA': localAppData},
            operatingSystem: 'windows',
          ),
          throwsA(isA<WorkerCacheError>()),
        );
      });
    }

    for (final home in [null, '', 'relative']) {
      test('rejects invalid HOME $home', () {
        final environment = <String, String>{'HOME': ?home};
        expect(
          () => workerCacheRoot(
            environment: environment,
            operatingSystem: 'linux',
          ),
          throwsA(
            isA<WorkerCacheError>().having(
              (error) => error.toString(),
              'message',
              contains('HOME'),
            ),
          ),
        );
      });
    }

    test('rejects when neither LOCALAPPDATA nor USERPROFILE is set', () {
      expect(
        () =>
            workerCacheRoot(environment: const {}, operatingSystem: 'windows'),
        throwsA(
          isA<WorkerCacheError>().having(
            (error) => error.toString(),
            'message',
            contains('USERPROFILE'),
          ),
        ),
      );
    });

    test('rejects unsupported operating systems', () {
      expect(
        () =>
            workerCacheRoot(environment: const {}, operatingSystem: 'fuchsia'),
        throwsA(isA<WorkerCacheError>()),
      );
    });

    for (final operatingSystem in ['macos', 'linux']) {
      test('uses HOME despite XDG_CACHE_HOME on $operatingSystem', () {
        const limited = {
          'HOME': '/home/ada',
          'PATH': '/bin',
          'TEMP': '/tmp',
          'TMP': '/tmp',
          'TMPDIR': '/tmp',
        };
        final full = {
          ...limited,
          'XDG_CACHE_HOME': '/elsewhere',
          'LOCALAPPDATA': '/other',
        };
        expect(
          workerCacheRoot(
            environment: limited,
            operatingSystem: operatingSystem,
          ),
          workerCacheRoot(environment: full, operatingSystem: operatingSystem),
        );
      });
    }
  });

  group('worker cache paths', () {
    const artifact = WorkerArtifact(
      file: 'dart_monty_worker',
      bytes: 1,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );

    test('builds paths from a POSIX root', () {
      const root = '/srv/dart-monty';
      const directory =
          '/srv/dart-monty/worker-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(workerCacheDir(root, artifact), directory);
      expect(workerCacheFile(root, artifact), '$directory/dart_monty_worker');
    });

    test('builds paths from a Windows root', () {
      const root = r'C:\Users\Ada\AppData\Local\dart_monty\Cache';
      const directory =
          r'C:\Users\Ada\AppData\Local\dart_monty\Cache\worker-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(workerCacheDir(root, artifact), directory);
      expect(workerCacheFile(root, artifact), '$directory\\dart_monty_worker');
    });
  });

  group('verifyWorkerFile', () {
    late Directory temporary;
    late File file;
    late WorkerArtifact artifact;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('worker_cache_test_');
      file = File('${temporary.path}/worker');
      final bytes = Uint8List(5 * 1024 * 1024);
      for (var index = 0; index < bytes.length; index++) {
        bytes[index] = index % 251;
      }
      await file.writeAsBytes(bytes, flush: true);
      artifact = WorkerArtifact(
        file: 'worker',
        bytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
    });

    tearDown(() => temporary.delete(recursive: true));

    test('accepts a matching multi-megabyte file', () async {
      await verifyWorkerFile(file, artifact);
    });

    test('reports a missing file', () async {
      await _expectReason(
        verifyWorkerFile(File('${temporary.path}/missing'), artifact),
        WorkerVerifyReason.missing,
      );
    });

    test('reports a directory path', () async {
      await _expectReason(
        verifyWorkerFile(File(temporary.path), artifact),
        WorkerVerifyReason.notAFile,
      );
    });

    test('reports a size mismatch', () async {
      await file.writeAsBytes([1], flush: true);
      await _expectReason(
        verifyWorkerFile(file, artifact),
        WorkerVerifyReason.size,
      );
    });

    test('reports a changed middle byte with the same size', () async {
      final randomAccess = await file.open(mode: FileMode.append);
      await randomAccess.close();
      final bytes = await file.readAsBytes();
      bytes[bytes.length ~/ 2] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await _expectReason(
        verifyWorkerFile(file, artifact),
        WorkerVerifyReason.digest,
      );
    });

    test('formats verification details for diagnostics', () {
      const error = WorkerVerifyError(
        path: '/cache/worker',
        reason: WorkerVerifyReason.digest,
        expected: 'expected-digest',
        actual: 'actual-digest',
      );
      expect(
        error.toString(),
        allOf(
          contains('/cache/worker'),
          contains('digest'),
          contains('expected-digest'),
          contains('actual-digest'),
        ),
      );
    });
  });
}

Future<void> _expectReason(Future<void> future, WorkerVerifyReason reason) =>
    expectLater(
      future,
      throwsA(
        isA<WorkerVerifyError>().having(
          (error) => error.reason,
          'reason',
          reason,
        ),
      ),
    );
