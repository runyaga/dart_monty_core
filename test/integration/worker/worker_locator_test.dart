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
import 'package:dart_monty_core/src/worker/worker_fingerprint.dart';
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

    test(
      'locator warm start skips a matching fingerprint verification',
      () async {
        resetVerifiedWorkersForTesting();
        await _withCachedWorker((environment, manifest, cached) async {
          writeWorkerFingerprint(
            cached,
            _fingerprint(cached, manifest),
          );
          var count = 0;
          Future<void> verify(File _, WorkerArtifact _) {
            count++;

            return Future.value();
          }

          final launch = await locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
              verify: verify,
            ),
          );

          expect((launch as WorkerExecutable).path, cached.path);
          expect(count, 0);
        });
      },
    );

    test(
      'locator warm start verifies once without a record then writes one',
      () async {
        resetVerifiedWorkersForTesting();
        await _withCachedWorker((environment, manifest, cached) async {
          var count = 0;
          Future<void> verify(File _, WorkerArtifact _) {
            count++;

            return Future.value();
          }

          final source = WorkerCacheSource(
            environment: environment,
            manifest: manifest,
            verify: verify,
          );

          Future<WorkerLaunch> locate() =>
              locateWorker(abi: Abi.current(), cache: source);

          for (var process = 0; process != 2; process++) {
            await locate();
            if (process == 0) {
              expect(count, 1);
              expect(
                readWorkerFingerprint(cached),
                statWorkerFingerprint(
                  cached,
                  workerEntryKey(_artifact, version: manifest.version),
                ),
              );
              resetVerifiedWorkersForTesting();
            }
          }
          expect(count, 1);
        });
      },
    );

    test(
      'locator re-verifies for a different manifest entry in one process',
      () async {
        resetVerifiedWorkersForTesting();
        await _withCachedWorker((environment, manifest, _) async {
          var count = 0;
          void verify(File _, WorkerArtifact _) => count++;
          final source = WorkerCacheSource(
            environment: environment,
            manifest: manifest,
            verify: verify,
          );

          await locateWorker(abi: Abi.current(), cache: source);
          await locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: WorkerManifest(
                version: 'another-version',
                targets: manifest.targets,
              ),
              verify: verify,
            ),
          );

          expect(count, 2);
        });
      },
    );

    test(
      'locator retains its pre-hash fingerprint after a changed verify',
      () async {
        resetVerifiedWorkersForTesting();
        await _withCachedWorker((environment, manifest, cached) async {
          final entry = workerEntryKey(_artifact, version: manifest.version);
          final before = statWorkerFingerprint(cached, entry);
          if (before == null) fail('seeded worker cannot be fingerprinted');
          var count = 0;
          Future<void> verify(File file, WorkerArtifact artifact) async {
            count++;
            await verifyWorkerFile(file, artifact);
            if (count == 1) {
              final bytes = file.readAsBytesSync()..[0] ^= 1;
              file
                ..writeAsBytesSync(bytes)
                ..setLastModifiedSync(
                  DateTime.fromMicrosecondsSinceEpoch(before.modifiedMicros),
                );
            }
          }

          final source = WorkerCacheSource(
            environment: environment,
            manifest: manifest,
            verify: verify,
          );
          await locateWorker(abi: Abi.current(), cache: source);
          expect(
            readWorkerFingerprint(cached),
            isNot(
              equals(
                statWorkerFingerprint(cached, entry),
              ),
            ),
          );

          resetVerifiedWorkersForTesting();
          await expectLater(
            locateWorker(abi: Abi.current(), cache: source),
            throwsA(isA<MontyCrashedError>()),
          );
          expect(count, 2);
        });
      },
      skip: Platform.isWindows
          ? 'change time is the creation time on Windows'
          : false,
    );

    test(
      'locator warm start rehashes each changed fingerprint field',
      () async {
        await _withCachedWorker((environment, manifest, cached) async {
          final entry = workerEntryKey(_artifact, version: manifest.version);
          final original = statWorkerFingerprint(cached, entry);
          if (original == null) fail('seeded worker cannot be fingerprinted');
          final sources = [
            WorkerFingerprint(
              size: original.size + 1,
              modifiedMicros: original.modifiedMicros,
              changedMicros: original.changedMicros,
              entry: original.entry,
            ),
            WorkerFingerprint(
              size: original.size,
              modifiedMicros: original.modifiedMicros + 1,
              changedMicros: original.changedMicros,
              entry: original.entry,
            ),
            WorkerFingerprint(
              size: original.size,
              modifiedMicros: original.modifiedMicros,
              changedMicros: original.changedMicros + 1,
              entry: original.entry,
            ),
            WorkerFingerprint(
              size: original.size,
              modifiedMicros: original.modifiedMicros,
              changedMicros: original.changedMicros,
              entry: workerEntryKey(_artifact, version: 'another-version'),
            ),
          ];
          for (final record in sources) {
            resetVerifiedWorkersForTesting();
            File(
              workerFingerprintPath(cached.path),
            ).writeAsStringSync(jsonEncode(record.toJson()));
            var count = 0;
            await locateWorker(
              abi: Abi.current(),
              cache: WorkerCacheSource(
                environment: environment,
                manifest: manifest,
                verify: (file, artifact) async => count++,
              ),
            );
            expect(count, 1);
          }
        });
      },
    );

    test('locator warm start rehashes absent and unusable records', () async {
      await _withCachedWorker((environment, manifest, cached) async {
        final record = File(workerFingerprintPath(cached.path));
        for (final source in [null, 'garbage', '']) {
          resetVerifiedWorkersForTesting();
          if (source == null) {
            if (record.existsSync()) record.deleteSync();
          } else {
            record.writeAsStringSync(source);
          }
          var count = 0;
          await locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
              verify: (file, artifact) async => count++,
            ),
          );
          expect(count, 1);
        }
      });
    });

    test('locator warm start fails closed after a corrupt record', () async {
      resetVerifiedWorkersForTesting();
      await _withCachedWorker((environment, manifest, cached) async {
        File(workerFingerprintPath(cached.path)).writeAsStringSync('garbage');
        await expectLater(
          locateWorker(
            abi: Abi.current(),
            cache: WorkerCacheSource(
              environment: environment,
              manifest: manifest,
              verify: (file, artifact) => Future.error(
                WorkerVerifyError(
                  path: file.path,
                  reason: WorkerVerifyReason.digest,
                  expected: artifact.sha256,
                  actual: 'bad',
                ),
              ),
            ),
            resolvePackageUri: (_) async => Uri.file('/fallback'),
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (error) => error.toString(),
              'message',
              contains(cached.path),
            ),
          ),
        );
      });
    });

    test(
      'locator warm start catches an mtime-restored modification',
      () async {
        resetVerifiedWorkersForTesting();
        await _withCachedWorker((environment, manifest, cached) async {
          writeWorkerFingerprint(cached, _fingerprint(cached, manifest));
          final original = readWorkerFingerprint(cached);
          if (original == null) fail('written fingerprint cannot be read');
          cached
            ..writeAsStringSync('evil')
            ..setLastModifiedSync(
              DateTime.fromMicrosecondsSinceEpoch(original.modifiedMicros),
            );
          var count = 0;

          await expectLater(
            locateWorker(
              abi: Abi.current(),
              cache: WorkerCacheSource(
                environment: environment,
                manifest: manifest,
                verify: (file, artifact) async {
                  count++;
                  throw WorkerVerifyError(
                    path: file.path,
                    reason: WorkerVerifyReason.digest,
                    expected: artifact.sha256,
                    actual: 'bad',
                  );
                },
              ),
            ),
            throwsA(isA<MontyCrashedError>()),
          );
          expect(count, 1);
        });
      },
      skip: Platform.isWindows
          ? 'change time is the creation time on Windows'
          : false,
    );

    test('locator warm start accepts a forged current record', () async {
      resetVerifiedWorkersForTesting();
      await _withCachedWorker((environment, manifest, cached) async {
        cached.writeAsStringSync('evil');
        writeWorkerFingerprint(
          cached,
          _fingerprint(cached, manifest),
        );
        var count = 0;

        await locateWorker(
          abi: Abi.current(),
          cache: WorkerCacheSource(
            environment: environment,
            manifest: manifest,
            verify: (file, artifact) async => count++,
          ),
        );
        expect(count, 0);
      });
    });

    test('locator warm start launches from a read-only cache', () async {
      if (Platform.isWindows) return;
      resetVerifiedWorkersForTesting();
      await _withCachedWorker((environment, manifest, cached) async {
        await Process.run('chmod', ['500', cached.parent.path]);
        addTearDown(() => Process.run('chmod', ['700', cached.parent.path]));
        var count = 0;

        final launch = await locateWorker(
          abi: Abi.current(),
          cache: WorkerCacheSource(
            environment: environment,
            manifest: manifest,
            verify: (file, artifact) async => count++,
          ),
        );
        expect((launch as WorkerExecutable).path, cached.path);
        expect(count, 1);
      });
    });

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

    test(
      'treats a non-executable verified cache entry as a hard error',
      () async {
        if (Platform.isWindows) return;

        await _withCachedWorker((environment, manifest, cached) async {
          await Process.run('chmod', ['600', cached.path]);
          addTearDown(() => Process.run('chmod', ['700', cached.path]));
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
                allOf(contains(cached.path), contains('non-executable')),
              ),
            ),
          );
        });
      },
    );

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

  group('launch selection', () {
    test('explicit launch wins in AOT', () async {
      var eligibilityChecks = 0;
      const explicit = WorkerExecutable('/chosen/worker', args: ['subprocess']);
      final launch = await locateWorker(
        explicit: explicit,
        selfRelaunch: const SelfRelaunchOptions(isAot: true),
        canSelfRelaunch: () {
          eligibilityChecks++;

          return true;
        },
      );
      expect(launch, same(explicit));
      expect(eligibilityChecks, 0);
    });

    test('JIT never asks self-relaunch eligibility', () async {
      runMontyWorkerIfChild(const []);
      expect(
        diagnoseSelfRelaunch(
          resolveWorker: _resolved,
          fileExists: (_) => true,
        ),
        isA<SelfRelaunchReady>(),
      );
      var eligibilityChecks = 0;
      final launch = await locateWorker(
        cache: WorkerCacheSource(manifest: WorkerManifest(targets: {})),
        resolvePackageUri: (_) async => Uri.file(Platform.resolvedExecutable),
        canSelfRelaunch: () {
          eligibilityChecks++;

          return true;
        },
      );
      expect((launch as WorkerExecutable).path, Platform.resolvedExecutable);
      expect(eligibilityChecks, 0);
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

void _resolved() => _resolutions++;
int _resolutions = 0;

WorkerFingerprint _fingerprint(File file, WorkerManifest manifest) =>
    statWorkerFingerprint(
      file,
      workerEntryKey(_artifact, version: manifest.version),
    ) ??
    (throw StateError('test worker cannot be fingerprinted'));
