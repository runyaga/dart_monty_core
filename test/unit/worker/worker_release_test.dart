@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:dart_monty_core/src/worker/worker_manifest_data.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../tool/worker_release.dart';

const _targets = [
  'macos-arm64',
  'linux-x64',
  'linux-arm64',
  'windows-x64',
];

void main() {
  group('pack', () {
    test('writes archives and a fragment for each binary pair', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final assetsPath = fixture.assets.path;

      for (final target in _targets) {
        final worker = File(
          path.join(assetsPath, 'dart_monty_worker-$target.gz'),
        );
        final library = File(
          path.join(
            assetsPath,
            'dart_monty_worker_library-$target.gz',
          ),
        );
        expect(worker.existsSync(), isTrue);
        expect(library.existsSync(), isTrue);
        expect(
          File(
            path.join(assetsPath, '$target.fragment.json'),
          ).existsSync(),
          isTrue,
        );
      }
    });

    test('rejects missing and empty input files', () async {
      final root = await Directory.systemTemp.createTemp('worker-release-');
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory(path.join(root.path, 'bin'));
      final out = Directory(path.join(root.path, 'out'));
      await bin.create();
      await expectLater(
        () => packWorkerRelease(
          'linux-x64',
          bin,
          out,
        ),
        throwsA(_releaseError('missing')),
      );
      await File(
        path.join(bin.path, 'dart_monty_worker'),
      ).writeAsString('worker');
      await File(
        path.join(bin.path, 'libdart_monty_worker.so'),
      ).writeAsString('');
      await expectLater(
        () => packWorkerRelease(
          'linux-x64',
          bin,
          out,
        ),
        throwsA(_releaseError('empty')),
      );
    });
  });

  group('manifest', () {
    test(
      'parses four targets and derives their default archive URLs',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final manifest = await fixture.manifest();

        expect(manifest.targets.keys, unorderedEquals(_targets));
        for (final target in _targets) {
          final worker = manifest.targets[target]?.worker;
          final archive = worker?.archive;
          if (archive == null) fail('worker archive is missing for $target');
          final url = defaultWorkerMirrorTemplate
              .replaceAll('{tag}', 'v1.2.3')
              .replaceAll('{archive}', archive.name);
          expect(path.basename(Uri.parse(url).path), archive.name);
          expect(
            File(path.join(fixture.assets.path, archive.name)).existsSync(),
            isTrue,
          );
        }
      },
    );

    test(
      'requires every target unless partial manifests are allowed',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        await File(
          path.join(fixture.assets.path, 'windows-x64.fragment.json'),
        ).delete();

        await expectLater(
          () => writeWorkerReleaseManifest(
            'v1.2.3',
            fixture.assets,
            fixture.manifestFile,
            allowPartial: false,
          ),
          throwsA(
            isA<WorkerRelease>().having(
              (error) => error.message,
              'message',
              contains('windows-x64'),
            ),
          ),
        );
        writeWorkerReleaseManifest(
          'v1.2.3',
          fixture.assets,
          fixture.manifestFile,
          allowPartial: true,
        );
        expect((await fixture.manifest()).targets.keys, hasLength(3));
      },
    );
  });

  group('verify', () {
    test('accepts untouched archives', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      verifyWorkerRelease(fixture.manifestFile, fixture.assets);
    });

    test('rejects a changed archive', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.workerArchive('linux-x64');
      final bytes = await archive.readAsBytes();
      bytes[0] ^= 1;
      await archive.writeAsBytes(bytes, flush: true);

      await fixture.expectVerificationFailure('dart_monty_worker-linux-x64.gz');
    });

    test('rejects a missing archive', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await (await fixture.workerArchive('linux-x64')).delete();

      await fixture.expectVerificationFailure('dart_monty_worker-linux-x64.gz');
    });

    test('rejects an archive that is not in the manifest', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await File(
        path.join(fixture.assets.path, 'unexpected.gz'),
      ).writeAsBytes([1]);

      await fixture.expectVerificationFailure('unexpected.gz');
    });

    test('rejects a wrong archive digest', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.changeManifest((root) {
        final archive = _archive(root, 'linux-x64');
        archive['sha256'] = '0' * 64;
      });

      await fixture.expectVerificationFailure('dart_monty_worker-linux-x64.gz');
    });

    test('rejects a wrong worker byte count', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.changeManifest((root) {
        final worker = _worker(root, 'linux-x64');
        worker['bytes'] = 1;
      });

      await fixture.expectVerificationFailure('dart_monty_worker-linux-x64.gz');
    });
  });
}

Map<String, Object?> _worker(Map<String, Object?> root, String target) {
  final worker = _target(root, target)['worker'];
  if (worker is! Map<String, Object?>) throw StateError('worker is missing');

  return worker;
}

Matcher _releaseError(String message) => isA<WorkerRelease>().having(
  (error) => error.message,
  'message',
  contains(message),
);

Map<String, Object?> _archive(Map<String, Object?> root, String target) {
  final archive = _worker(root, target)['archive'];
  if (archive is! Map<String, Object?>) throw StateError('archive is missing');

  return archive;
}

Map<String, Object?> _target(Map<String, Object?> root, String target) {
  final targets = root['targets'];
  if (targets is! Map<String, Object?>) throw StateError('targets are missing');
  final entry = targets[target];
  if (entry is! Map<String, Object?>) throw StateError('target is missing');

  return entry;
}

final class _Fixture {
  const _Fixture(this.root, this.assets, this.manifestFile);

  final Directory root;
  final Directory assets;
  final File manifestFile;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('worker-release-');
    final assets = Directory(path.join(root.path, 'assets'));
    final manifest = File(path.join(root.path, 'worker-manifest.json'));
    final fixture = _Fixture(root, assets, manifest);
    for (final target in _targets) {
      await fixture._pack(target);
    }
    writeWorkerReleaseManifest(
      'v1.2.3',
      assets,
      manifest,
      allowPartial: false,
    );

    return fixture;
  }

  Future<WorkerManifest> manifest() async =>
      WorkerManifest.fromJson(await manifestFile.readAsString());

  Future<File> workerArchive(String target) async {
    final archive = (await manifest()).targets[target]?.worker.archive;
    if (archive == null) fail('worker archive is missing for $target');

    return File(path.join(assets.path, archive.name));
  }

  Future<void> changeManifest(
    void Function(Map<String, Object?>) change,
  ) async {
    final document =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    change(document);
    await manifestFile.writeAsString(jsonEncode(document));
  }

  Future<void> expectVerificationFailure(String archive) async {
    await expectLater(
      () => verifyWorkerRelease(manifestFile, assets),
      throwsA(
        isA<WorkerRelease>().having(
          (error) => error.message,
          'message',
          contains(archive),
        ),
      ),
    );
  }

  Future<void> dispose() => root.delete(recursive: true);

  Future<void> _pack(String target) async {
    final bin = Directory(path.join(root.path, 'bin', target));
    await bin.create(recursive: true);
    final windows = target == 'windows-x64';
    await File(
      path.join(
        bin.path,
        windows ? 'dart_monty_worker.exe' : 'dart_monty_worker',
      ),
    ).writeAsString('worker for $target');
    final library = switch (target) {
      'macos-arm64' => 'libdart_monty_worker.dylib',
      'windows-x64' => 'dart_monty_worker.dll',
      _ => 'libdart_monty_worker.so',
    };
    await File(
      path.join(bin.path, library),
    ).writeAsString('library for $target');
    packWorkerRelease(target, bin, assets);
  }
}
