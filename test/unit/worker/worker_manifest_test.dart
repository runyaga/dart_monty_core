@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

const _a64 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b64 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('WorkerManifest', () {
    test(
      'parses and verifies distinct worker, library, and archive artifacts',
      () async {
        const workerContents = 'worker';
        const libraryContents = 'library-data';
        const archiveContents = 'archive-content-data';
        final workerDigest = sha256
            .convert(utf8.encode(workerContents))
            .toString();
        final libraryDigest = sha256
            .convert(utf8.encode(libraryContents))
            .toString();
        final archiveDigest = sha256
            .convert(utf8.encode(archiveContents))
            .toString();
        final manifest = WorkerManifest.fromJson('''
        {"schema":1,"version":"v1.2.3","mirror":"https://x/{archive}",
        "targets":{"macos-arm64":{"worker":{"file":"worker","bytes":${utf8.encode(workerContents).length},
        "sha256":"$workerDigest",
        "archive":{"name":"worker.tar.gz","bytes":${utf8.encode(archiveContents).length},
        "sha256":"$archiveDigest"}},
        "library":{"file":"library.dylib","bytes":${utf8.encode(libraryContents).length},
        "sha256":"$libraryDigest"}}}}
      ''');

        final target = manifest.targetFor('macos-arm64');
        final worker = target?.worker;
        final library = target?.library;
        expect(manifest.version, 'v1.2.3');
        expect(manifest.mirror, 'https://x/{archive}');
        expect(worker?.file, 'worker');
        expect(worker?.bytes, utf8.encode(workerContents).length);
        expect(worker?.sha256, workerDigest);
        expect(worker?.archive?.name, 'worker.tar.gz');
        expect(worker?.archive?.bytes, utf8.encode(archiveContents).length);
        expect(worker?.archive?.sha256, archiveDigest);
        expect(library?.file, 'library.dylib');
        expect(library?.bytes, utf8.encode(libraryContents).length);
        expect(library?.sha256, libraryDigest);

        final temporary = await Directory.systemTemp.createTemp(
          'worker_manifest_',
        );
        addTearDown(() => temporary.delete(recursive: true));
        if (worker == null) fail('worker artifact missing');
        final workerFile = File('${temporary.path}/${worker.file}');
        await workerFile.writeAsString(workerContents);
        await verifyWorkerFile(workerFile, worker);
      },
    );

    test('accepts empty targets', () {
      expect(
        WorkerManifest.fromJson('{"schema":1,"targets":{}}').targets,
        isEmpty,
      );
    });

    test('rejects invalid schema values', () {
      expect(
        () => WorkerManifest.fromJson('{"schema":2,"targets":{}}'),
        throwsA(
          isA<WorkerManifestError>().having(
            (error) => error.toString(),
            'message',
            contains('schema'),
          ),
        ),
      );
    });

    test('rejects missing targets maps', () {
      expect(
        () => WorkerManifest.fromJson('{"schema":1}'),
        throwsA(
          isA<WorkerManifestError>().having(
            (error) => error.toString(),
            'message',
            contains('targets'),
          ),
        ),
      );
    });

    test('rejects an unsupported target key', () {
      _expectManifestError(
        '{"schema":1,"targets":{"fuchsia-x64":{}}}',
        'targets.fuchsia-x64 is unsupported',
      );
    });

    test('rejects a worker that is not a map', () {
      _expectManifestError(
        '{"schema":1,"targets":{"linux-x64":{"worker":[]}}}',
        'targets.linux-x64.worker',
      );
    });

    test('rejects a library that is not a map', () {
      _expectManifestError(
        '{"schema":1,"targets":{"linux-x64":{"worker":'
            '{"file":"worker","bytes":1,"sha256":"$_a64"},'
            '"library":[]}}}',
        'targets.linux-x64.library',
      );
    });

    test('rejects malformed JSON', () {
      _expectManifestError('{"schema":', 'JSON');
    });

    test('rejects a JSON root that is not an object', () {
      _expectManifestError('[]', 'root');
    });

    test('rejects a nested map with a non-string key', () {
      _expectStringMapError(
        {1: 'worker'},
        'targets.linux-x64.worker',
        'targets.linux-x64.worker',
      );
    });

    test('rejects a non-map nested value with its key', () {
      _expectStringMapError(
        const [],
        'targets.linux-x64.worker',
        'targets.linux-x64.worker',
      );
    });

    test('rejects non-string mirrors', () {
      expect(
        () => WorkerManifest.fromJson('{"schema":1,"mirror":3,"targets":{}}'),
        throwsA(isA<WorkerManifestError>()),
      );
    });

    for (final value in [
      'ABC',
      _a64.substring(1),
      '${_a64.substring(0, 63)}g',
    ]) {
      test('rejects invalid sha256 $value', () {
        expect(
          () => WorkerManifest.fromJson(_withArtifact('"sha256":"$value"')),
          throwsA(
            isA<WorkerManifestError>().having(
              (error) => error.toString(),
              'message',
              contains('sha256'),
            ),
          ),
        );
      });
    }

    for (final value in [0, -1]) {
      test('rejects non-positive bytes $value', () {
        expect(
          () => WorkerManifest.fromJson(_withArtifact('"bytes":$value')),
          throwsA(
            isA<WorkerManifestError>().having(
              (error) => error.toString(),
              'message',
              contains('bytes'),
            ),
          ),
        );
      });
    }

    for (final file in ['', '.', '..', 'dir/file', r'dir\\file']) {
      test('rejects non-basename file $file', () {
        expect(
          () => WorkerManifest.fromJson(_withArtifact('"file":"$file"')),
          throwsA(
            isA<WorkerManifestError>().having(
              (error) => error.toString(),
              'message',
              contains('file'),
            ),
          ),
        );
      });
    }

    test('rejects non-basename archive names', () {
      expect(
        () => WorkerManifest.fromJson(
          _withArtifact(
            '"archive":{"name":"dir/file","bytes":2,"sha256":"$_b64"}',
          ),
        ),
        throwsA(
          isA<WorkerManifestError>().having(
            (error) => error.toString(),
            'message',
            contains('archive.name'),
          ),
        ),
      );
    });

    test('returns null for an absent target', () {
      final manifest = WorkerManifest.fromJson('{"schema":1,"targets":{}}');
      expect(manifest.targetFor('linux-x64'), isNull);
    });
  });
}

String _withArtifact(String replacement) {
  return '{"schema":1,"targets":{"linux-x64":{"worker":'
      '{"file":"worker","bytes":1,"sha256":"$_a64",$replacement}}}}';
}

void _expectManifestError(String source, String key) {
  expect(
    () => WorkerManifest.fromJson(source),
    throwsA(
      isA<WorkerManifestError>().having(
        (error) => error.toString(),
        'message',
        contains(key),
      ),
    ),
  );
}

void _expectStringMapError(Object? value, String key, String messageKey) {
  expect(
    () => _stringMap(value, key),
    throwsA(
      isA<WorkerManifestError>().having(
        (error) => error.toString(),
        'message',
        contains(messageKey),
      ),
    ),
  );
}

Object? _stringMap(Object? value, String key) {
  LibraryMirror? manifestLibrary;
  for (final candidate in currentMirrorSystem().libraries.values) {
    if (candidate.uri.path.endsWith('/src/worker/worker_manifest.dart')) {
      manifestLibrary = candidate;
      break;
    }
  }
  if (manifestLibrary == null) {
    fail('worker manifest library is not loaded');
  }

  return manifestLibrary.invoke(
    MirrorSystem.getSymbol('_stringMap', manifestLibrary),
    [
      value,
      key,
    ],
  ).reflectee;
}
