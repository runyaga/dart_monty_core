// Self-relaunch under the JIT, where the worker library is never bundled:
// how the launch is spelled, what the child does with the flag, and that the
// locator only offers SelfRelaunch when the process can serve it. The
// relaunch itself runs in CI's `test-aot` job, in a `dart build cli` app.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedError;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

final String _probe = File(
  'test/integration/worker/self_relaunch_probe.dart',
).absolute.path;

void main() {
  _testLaunchCommand();
  _testDiagnosticFormatting();
  _testUnflaggedWorker();
  _testFlaggedWorker();
  _testWorkerLibraryExitCode();
  _testAotEligibility();
  _testAotRoute();
}

void _testLaunchCommand() {
  group('launchCommand', () {
    test('SelfRelaunch runs this executable with the worker flag', () {
      final (path, args) = launchCommand(const SelfRelaunch());
      expect(path, Platform.resolvedExecutable);
      expect(args, ['--dart-monty-core-worker']);
      expect(args, [SelfRelaunch.flag]);
    });

    test('WorkerExecutable runs its path with its arguments', () {
      final (path, args) = launchCommand(
        const WorkerExecutable('/opt/monty', args: ['subprocess']),
      );
      expect(path, '/opt/monty');
      expect(args, ['subprocess']);
    });

    test('SelfRelaunch.toString', () {
      expect(const SelfRelaunch().toString(), 'SelfRelaunch()');
    });
  });
}

void _testDiagnosticFormatting() {
  group('runMontyWorkerIfChild', () {
    test('worker child failure line covers every self-relaunch status', () {
      const library = '/bundle/lib/libdart_monty_worker.so';
      final cases = <(SelfRelaunchStatus, String?)>[
        (const SelfRelaunchReady(), null),
        (const SelfRelaunchNotArmed(), null),
        (const SelfRelaunchLibraryMissing(library), library),
        (
          const SelfRelaunchLibraryUnloadable(
            library,
            'ArgumentError: bad library\n  trailing detail\n',
          ),
          library,
        ),
      ];

      for (final (status, failurePath) in cases) {
        final line = workerChildFailureLine(status);
        if (failurePath == null) {
          expect(line, isNull, reason: '$status');
          continue;
        }

        expect(
          line,
          allOf(
            startsWith('dart_monty_core worker:'),
            contains(failurePath),
            contains('dart_monty_worker_main'),
          ),
          reason: '$status',
        );
        if (line == null) fail('missing child failure line for $status');
        expect(line.split('\n'), hasLength(1), reason: '$status');
      }
    });
  });
}

void _testUnflaggedWorker() {
  group('runMontyWorkerIfChild', () {
    test(
      'without the flag it returns, and arms nothing it cannot serve',
      () async {
        final output = await _unbundled();
        expect(output, contains('before=false\nafter=false\n'));
      },
    );

    test('a process started without the flag carries on as the app', () async {
      final r = await Process.run(Platform.resolvedExecutable, [_probe, 'x']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, 'available=false\nparent\n');
    });
  });
}

void _testFlaggedWorker() {
  group('runMontyWorkerIfChild', () {
    test(
      'the flag reports a missing bundled worker library and exits 78',
      () async {
        final r = await Process.run(Platform.resolvedExecutable, [
          _probe,
          SelfRelaunch.flag,
        ]);
        expect(r.stdout, isEmpty);
        expect(r.exitCode, 78);
        final lines = (r.stderr as String)
            .split('\n')
            .where((line) => line.isNotEmpty)
            .toList();
        expect(
          lines.singleOrNull,
          allOf(
            startsWith('dart_monty_core worker:'),
            contains('dart_monty_worker_main'),
            contains(_expectedWorkerLibraryPath()),
            isNot(contains('exit status: 255')),
          ),
        );
      },
    );

    test('the flag must be the only argument', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        _probe,
        SelfRelaunch.flag,
        'x',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, 'available=false\nparent\n');
    });
  });
}

void _testWorkerLibraryExitCode() {
  test('worker-library exit status is 78', () {
    expect(workerLibraryExitCode, 78);
  });
}

void _testAotEligibility() {
  group('locateWorker step 3 (AOT)', () {
    test('self-relaunch ready: SelfRelaunch', () {
      expect(
        locateWorker(
          selfRelaunch: const SelfRelaunchOptions(isAot: true),
          canSelfRelaunch: () => true,
        ),
        completion(isA<SelfRelaunch>()),
      );
    });

    test('not ready: a spawn failure naming both requirements', () {
      expect(
        locateWorker(
          selfRelaunch: const SelfRelaunchOptions(isAot: true),
          canSelfRelaunch: () => false,
        ),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('AOT'),
              contains('runMontyWorkerIfChild'),
              contains('build_worker: true'),
            ),
          ),
        ),
      );
    });
  });
}

void _testAotRoute() {
  group('locateWorker step 3 (AOT)', () {
    test('package URIs are not consulted, even where they resolve', () {
      var asked = false;
      expect(
        locateWorker(
          selfRelaunch: const SelfRelaunchOptions(isAot: true),
          resolvePackageUri: (uri) async {
            asked = true;

            return Uri.file(Platform.resolvedExecutable);
          },
          canSelfRelaunch: () => true,
        ),
        completion(isA<SelfRelaunch>()),
      );
      expect(asked, isFalse);
    });

    test('by default it asks this process, which is not ready', () async {
      expect(await _unbundled(), contains('locator=spawn failure\n'));
    });

    test('under the JIT it never offers SelfRelaunch', () {
      expect(
        locateWorker(
          cache: WorkerCacheSource(manifest: WorkerManifest(targets: {})),
          resolvePackageUri: (_) async => null,
          canSelfRelaunch: () => true,
        ),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            contains('package URIs do not resolve'),
          ),
        ),
      );
    });
  });
}

String _expectedWorkerLibraryPath() {
  final name = switch (Platform.operatingSystem) {
    'windows' => 'dart_monty_worker.dll',
    'macos' => 'libdart_monty_worker.dylib',
    _ => 'libdart_monty_worker.so',
  };

  return path.normalize(
    path.join(path.dirname(Platform.resolvedExecutable), '..', 'lib', name),
  );
}

// Native mounts load the worker dylib into the test process. Its global
// symbols can then satisfy @Native in any test isolate, so absence must be
// measured in a fresh process, as F-0's route-2 lookup check does.
Future<String> _unbundled() async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'test/integration/worker/self_relaunch_unbundled_probe.dart',
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

  return result.stdout as String;
}
