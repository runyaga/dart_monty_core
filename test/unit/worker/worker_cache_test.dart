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
    test('uses the macOS HOME cache directory', () {
      expect(
        workerCacheRoot(
          environment: {'HOME': '/Users/ada'},
          operatingSystem: 'macos',
        ),
        '/Users/ada/Library/Caches/dart_monty',
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

    test('rejects a missing LOCALAPPDATA', () {
      expect(
        () =>
            workerCacheRoot(environment: const {}, operatingSystem: 'windows'),
        throwsA(
          isA<WorkerCacheError>().having(
            (error) => error.toString(),
            'message',
            contains('LOCALAPPDATA'),
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
