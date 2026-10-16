// Where the worker executable is looked for, and what is said when it is not
// there.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedError;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('workerPackagePath', () {
    test('<os>-<arch>, no extension off Windows', () {
      expect(
        workerPackagePath(Abi.linuxX64),
        'src/bin/linux-x64/dart_monty_worker',
      );
      expect(
        workerPackagePath(Abi.macosArm64),
        'src/bin/macos-arm64/dart_monty_worker',
      );
    });

    test('.exe on Windows', () {
      expect(
        workerPackagePath(Abi.windowsX64),
        'src/bin/windows-x64/dart_monty_worker.exe',
      );
    });
  });

  group('locateWorker', () {
    for (final (
          description,
          status,
          expected,
        )
        in <(String, SelfRelaunchStatus, List<String>)>[
          (
            'an app that did not arm itself',
            const SelfRelaunchNotArmed(),
            [
              'runMontyWorkerIfChild(args)',
              'first statement',
              'WorkerExecutable',
            ],
          ),
          (
            'a missing bundled library',
            const SelfRelaunchLibraryMissing(
              '/bundle/lib/libdart_monty_worker.so',
            ),
            [
              '/bundle/lib/libdart_monty_worker.so',
              'ship the bundle',
              'WorkerExecutable',
            ],
          ),
          (
            'an unloadable bundled library',
            const SelfRelaunchLibraryUnloadable(
              '/bundle/lib/libdart_monty_worker.so',
              'invalid shared library',
            ),
            [
              '/bundle/lib/libdart_monty_worker.so',
              'invalid shared library',
              'rebuild it for this platform',
              'WorkerExecutable',
            ],
          ),
        ]) {
      test(
        'reports $description with its remedy instead of status 255',
        () async {
          await expectLater(
            locateWorker(
              selfRelaunch: SelfRelaunchOptions(
                isAot: true,
                diagnose: () => status,
              ),
              canSelfRelaunch: () => false,
            ),
            throwsA(
              isA<MontyCrashedError>().having(
                (error) => error.toString(),
                'message',
                allOf(
                  [...expected.map(contains), isNot(contains('255'))],
                ),
              ),
            ),
          );
        },
      );
    }

    test('an explicit launch wins', () async {
      const explicit = WorkerExecutable('/opt/monty', args: ['subprocess']);
      expect(await locateWorker(explicit: explicit), same(explicit));
    });

    test('none built: a spawn failure naming the path and the fix', () async {
      await expectLater(
        locateWorker(abi: Abi.fuchsiaRiscv64),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              startsWith('failed to spawn monty worker: '),
              contains('src/bin/fuchsia-riscv64/dart_monty_worker'),
              contains('tool/build_worker.sh'),
            ),
          ),
        ),
      );
    });

    test('uses a JIT cache entry before the package-relative worker', () async {
      await _withCachedWorker((environment, manifest, cached) async {
        final package = await _packageFile('package-worker');
        final launch = await locateWorker(
          abi: Abi.current(),
          cache: WorkerCacheSource(
            environment: environment,
            manifest: manifest,
          ),
          resolvePackageUri: (_) async => package.uri,
        );
        expect((launch as WorkerExecutable).path, cached.path);
      });
    });

    test('uses an explicit worker before a cache entry', () async {
      await _withCachedWorker((environment, manifest, _) async {
        const explicit = WorkerExecutable('/opt/explicit');
        expect(
          await locateWorker(
            explicit: explicit,
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
            ),
          ),
          same(explicit),
        );
      });
    });

    test('verifies a cache entry once per process', () async {
      resetVerifiedWorkersForTesting();
      await _withCachedWorker((environment, manifest, _) async {
        var count = 0;
        Future<void> verify(File _, WorkerArtifact _) =>
            Future.microtask(() => count++);
        for (var index = 0; index != 2; index++) {
          await locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
              verify: verify,
            ),
          );
        }
        expect(count, 1);
      });
    });

    test('treats a corrupt cache entry as a hard error', () async {
      await _withCachedWorker((environment, manifest, cached) async {
        await cached.writeAsString('corrupt');
        final package = await _packageFile('package-worker');
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
            ),
            resolvePackageUri: (_) async => package.uri,
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains(cached.path),
                contains('delete'),
                contains('dart run'),
              ),
            ),
          ),
        );
      });
    });

    test('treats an unreadable cache entry as a hard error', () async {
      if (Platform.isWindows) return;

      await _withCachedWorker((environment, manifest, cached) async {
        await Process.run('chmod', ['000', cached.path]);
        addTearDown(() => Process.run('chmod', ['600', cached.path]));
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
            ),
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains(cached.path),
                contains('OS Error'),
                contains('delete'),
                contains('dart run'),
              ),
            ),
          ),
        );
      });
    });

    test('translates a file-system error from cache verification', () async {
      await _withCachedWorker((environment, manifest, cached) async {
        Future<void> verify(File file, WorkerArtifact _) => Future.error(
          FileSystemException(
            'Unable to read worker',
            file.path,
            const OSError('Permission denied', 13),
          ),
        );
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
              verify: verify,
            ),
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains(cached.path),
                contains('Permission denied'),
                contains('delete'),
                contains('dart run'),
              ),
            ),
          ),
        );
      });
    });

    test(
      'falls through to the package-relative worker for a missing cache',
      () async {
        await _withTemporaryHome((environment) async {
          final package = await _packageFile('package-worker');
          final launch = await locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: _manifestForHost(),
            ),
            resolvePackageUri: (_) async => package.uri,
          );
          expect((launch as WorkerExecutable).path, package.path);
        });
      },
    );

    test('names cache and package paths when neither worker exists', () async {
      await _withTemporaryHome((environment) async {
        final artifact = _artifact;
        final cachePath = workerCacheFile(
          workerCacheRoot(environment: environment),
          artifact,
        );
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: _manifestForHost(),
            ),
            resolvePackageUri: (_) async => null,
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(contains(cachePath), contains('package:dart_monty_core')),
            ),
          ),
        );
      });
    });

    test(
      'does not fall through when the cache entry cannot be inspected',
      () async {
        if (Platform.isWindows) return;

        await _withCachedWorker((environment, manifest, cached) async {
          final cacheDirectory = cached.parent;
          await Process.run('chmod', ['600', cacheDirectory.path]);
          addTearDown(() => Process.run('chmod', ['700', cacheDirectory.path]));
          final package = await _packageFile('package-worker');
          await expectLater(
            locateWorker(
              abi: Abi.current(),
              cache: WorkerCacheSource(
                environment: environment,
                manifest: manifest,
              ),
              resolvePackageUri: (_) async => package.uri,
            ),
            throwsA(
              isA<MontyCrashedError>().having(
                (error) => error.toString(),
                'message',
                allOf(contains(cached.path), contains('OS Error')),
              ),
            ),
          );
        });
      },
    );

    test('uses self-relaunch in AOT mode before the cache', () async {
      await _withCachedWorker((environment, manifest, _) async {
        expect(
          await locateWorker(
            abi: Abi.current(),
            selfRelaunch: const SelfRelaunchOptions(isAot: true),
            canSelfRelaunch: () => true,
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
            ),
          ),
          isA<SelfRelaunch>(),
        );
      });
    });

    test('skips the cache when the manifest lacks the host target', () async {
      await _withTemporaryHome((environment) async {
        final package = await _packageFile('package-worker');
        final launch = await locateWorker(
          abi: Abi.current(),
          cache: WorkerCacheSource(
            environment: environment,
            manifest: WorkerManifest(targets: const {}),
          ),
          resolvePackageUri: (_) async => package.uri,
        );
        expect((launch as WorkerExecutable).path, package.path);
      });
    });

    for (final operatingSystem in ['linux', 'macos', 'windows']) {
      test('reports an invalid $operatingSystem cache environment', () async {
        final variable = operatingSystem == 'windows' ? 'LOCALAPPDATA' : 'HOME';
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: {variable: 'relative'},
              operatingSystem: operatingSystem,
              manifest: _manifestForHost(),
            ),
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains(variable),
                contains('set $variable to an absolute directory'),
                contains('WorkerExecutable'),
              ),
            ),
          ),
        );
      });
    }

    test('treats a dangling cache symlink as a hard error', () async {
      if (Platform.isWindows) return;

      await _withTemporaryHome((environment) async {
        final cache = File(
          workerCacheFile(workerCacheRoot(environment: environment), _artifact),
        );
        await cache.parent.create(recursive: true);
        await Link(cache.path).create('${cache.parent.path}/missing');
        final package = await _packageFile('package-worker');
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: _manifestForHost(),
            ),
            resolvePackageUri: (_) async => package.uri,
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              allOf(contains(cache.path), contains('invalid')),
            ),
          ),
        );
      });
    });
  });
}

final _artifact = WorkerArtifact(
  file: 'worker',
  bytes: 4,
  sha256: sha256.convert(utf8.encode('good')).toString(),
);

WorkerManifest _manifestForHost() => WorkerManifest(
  targets: {workerHostKey(Abi.current()): WorkerTarget(worker: _artifact)},
);

Future<void> _withCachedWorker(
  Future<void> Function(Map<String, String>, WorkerManifest, File) body,
) => _withTemporaryHome((environment) async {
  final cache = File(
    workerCacheFile(workerCacheRoot(environment: environment), _artifact),
  );
  await cache.parent.create(recursive: true);
  await cache.writeAsString('good');
  if (!Platform.isWindows) {
    await Process.run('chmod', ['+x', cache.path]);
  }
  await body(environment, _manifestForHost(), cache);
});

Future<void> _withTemporaryHome(
  Future<void> Function(Map<String, String>) body,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'worker_locator_test_',
  );
  addTearDown(() => directory.delete(recursive: true));
  await body({
    if (Platform.isWindows)
      'LOCALAPPDATA': directory.path
    else
      'HOME': directory.path,
  });
}

Future<File> _packageFile(String name) async {
  final directory = await Directory.systemTemp.createTemp(
    'worker_package_test_',
  );
  addTearDown(() => directory.delete(recursive: true));

  return File('${directory.path}/$name')..writeAsStringSync('package');
}
