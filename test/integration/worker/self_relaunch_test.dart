// Self-relaunch under the JIT, where the worker library is never bundled:
// how the launch is spelled, what the child does with the flag, and that the
// locator only offers SelfRelaunch when the process can serve it. The
// relaunch itself runs in CI's `test-aot` job, in a `dart build cli` app.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedError;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:test/test.dart';

final String _probe = File(
  'test/integration/worker/self_relaunch_probe.dart',
).absolute.path;

void main() {
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

  group('runMontyWorkerIfChild', () {
    test('without the flag it returns, and arms nothing it cannot serve', () {
      final beforeCall = selfRelaunchAvailable();
      runMontyWorkerIfChild(const ['--other']);
      final afterCall = selfRelaunchAvailable();
      expect(beforeCall, isFalse, reason: 'not yet called');
      // Called, but `dart test` builds no worker library (no opt-in).
      expect(afterCall, isFalse);
    });

    test('a process started without the flag carries on as the app', () async {
      final r = await Process.run(Platform.resolvedExecutable, [_probe, 'x']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, 'available=false\nparent\n');
    });

    test('the flag hands the process to the worker library, which this '
        'runtime does not have', () async {
      final r = await Process.run(Platform.resolvedExecutable, [
        _probe,
        SelfRelaunch.flag,
      ]);
      // Never returned to main: nothing on stdout, and the failure names the
      // missing entry point.
      expect(r.stdout, isEmpty);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('dart_monty_worker_main'));
    });

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

  group('locateWorker step 3 (AOT)', () {
    test('self-relaunch ready: SelfRelaunch', () {
      expect(
        locateWorker(isAot: true, canSelfRelaunch: () => true),
        completion(isA<SelfRelaunch>()),
      );
    });

    test('not ready: a spawn failure naming both requirements', () {
      expect(
        locateWorker(isAot: true, canSelfRelaunch: () => false),
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

    test('package URIs are not consulted, even where they resolve', () {
      var asked = false;
      expect(
        locateWorker(
          isAot: true,
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

    test('by default it asks this process, which is not ready', () {
      expect(locateWorker(isAot: true), throwsA(isA<MontyCrashedError>()));
    });

    test('under the JIT it never offers SelfRelaunch', () {
      expect(
        locateWorker(
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
