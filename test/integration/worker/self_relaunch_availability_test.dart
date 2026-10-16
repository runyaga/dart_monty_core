// Keep the arming and resolution checks inside the measured test isolate.
// Other suites can load the mount dylib process-wide, so simulate absence
// only at symbol resolution; real absence is checked by the unbundled probe.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:test/test.dart';

void main() {
  test('diagnosis reports an app that did not arm self-relaunch', () {
    var resolutions = 0;
    void missingWorker() {
      resolutions++;
      throw ArgumentError('worker symbol is absent');
    }

    final unarmed = diagnoseSelfRelaunch(resolveWorker: missingWorker);
    expect(unarmed, isA<SelfRelaunchNotArmed>());
    expect(resolutions, 0, reason: 'unarmed apps must not load the library');
  });

  test('diagnosis names an absent bundled worker library for each host', () {
    runMontyWorkerIfChild(const ['--other']);
    for (final (operatingSystem, executable, expected) in [
      (
        'macos',
        '/bundle/bin/application',
        '/bundle/lib/libdart_monty_worker.dylib',
      ),
      (
        'linux',
        '/bundle/bin/application',
        '/bundle/lib/libdart_monty_worker.so',
      ),
      (
        'windows',
        r'C:\bundle\bin\application.exe',
        r'C:\bundle\lib\dart_monty_worker.dll',
      ),
    ]) {
      final status = diagnoseSelfRelaunch(
        executablePath: executable,
        fileExists: (_) => false,
        operatingSystem: operatingSystem,
      );
      expect(
        status,
        isA<SelfRelaunchLibraryMissing>().having(
          (missing) => missing.path,
          'path',
          expected,
        ),
      );
    }
  });

  test(
    'diagnosis checks for the bundled library before resolving its symbol',
    () {
      var resolutions = 0;
      final status = diagnoseSelfRelaunch(
        executablePath: '/bundle/bin/application',
        fileExists: (_) => false,
        operatingSystem: 'linux',
        resolveWorker: () {
          resolutions++;
          throw ArgumentError('worker symbol is absent');
        },
      );
      expect(status, isA<SelfRelaunchLibraryMissing>());
      expect(resolutions, 0);
    },
  );

  test('diagnosis names an unloadable bundled worker library', () {
    final status = diagnoseSelfRelaunch(
      executablePath: '/bundle/bin/application',
      fileExists: (_) => true,
      operatingSystem: 'linux',
      resolveWorker: () => throw ArgumentError('worker symbol is corrupt'),
    );
    expect(
      status,
      isA<SelfRelaunchLibraryUnloadable>()
          .having(
            (unloadable) => unloadable.path,
            'path',
            '/bundle/lib/libdart_monty_worker.so',
          )
          .having(
            (unloadable) => unloadable.error,
            'error',
            contains('worker symbol is corrupt'),
          ),
    );
  });

  test('diagnosis reports a bundled and resolvable worker as ready', () {
    expect(
      diagnoseSelfRelaunch(
        executablePath: '/bundle/bin/application',
        fileExists: (_) => true,
        operatingSystem: 'linux',
        resolveWorker: _resolvable,
      ),
      isA<SelfRelaunchReady>(),
    );
  });

  test('self-relaunch does not hide unrelated resolver failures', () {
    final failure = StateError('resolver failed');
    expect(
      () => diagnoseSelfRelaunch(
        executablePath: '/bundle/bin/application',
        fileExists: (_) => true,
        resolveWorker: () => throw failure,
      ),
      throwsA(same(failure)),
    );
  });
}

void _resolvable() => Object();
