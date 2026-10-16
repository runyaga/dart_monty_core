// Keep the arming and resolution checks inside the measured test isolate.
// Other suites can load the mount dylib process-wide, so simulate absence
// only at symbol resolution; real absence is checked by the unbundled probe.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/process_channel.dart'
    show SelfRelaunch;
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    runMontyWorkerIfChild(const ['--other']);
  });

  _testChildHandoff();
  _testUnarmedApp();
  _testMissingLibrary();
  _testUnloadableLibrary();
  _testReadyLibrary();
  _testUnrelatedFailure();
}

void _testChildHandoff() {
  group('in-process child handoff', () {
    test(
      'a resolvable entry runs the worker main and exits with its code',
      () async {
        final result = await Isolate.run(_runResolvableChild);
        expect(result.resolutions, 1);
        expect(result.workerMains, 1);
        expect(result.stderrLines, isEmpty);
        expect(result.exitCodes, [23]);
      },
    );

    for (final (name, status) in <(String, SelfRelaunchStatus)>[
      (
        'missing library',
        const SelfRelaunchLibraryMissing('/bundle/lib/dart_monty_worker.so'),
      ),
      (
        'unloadable library',
        const SelfRelaunchLibraryUnloadable(
          '/bundle/lib/dart_monty_worker.so',
          'invalid shared library',
        ),
      ),
    ]) {
      test('$name writes one diagnostic and exits 78', () async {
        final result = await Isolate.run(() => _runFailedChild(status));
        expect(
          result.workerMains,
          0,
          reason: 'a failed child writes no stdout',
        );
        expect(result.stderrLines, hasLength(1));
        expect(result.stderrLines.single, contains('dart_monty_worker_main'));
        expect(result.exitCodes, [workerLibraryExitCode]);
      });
    }

    test('a non-worker invocation arms self-relaunch and returns', () async {
      expect(await Isolate.run(_runParent), isTrue);
    });

    test('the worker flag with extra arguments arms and returns', () async {
      expect(await Isolate.run(_runFlagWithExtraArguments), isTrue);
    });
  });
}

void _testUnarmedApp() {
  test('diagnosis reports an app that did not arm self-relaunch', () async {
    final (unarmed, resolutions) = await Isolate.run(_diagnoseUnarmed);
    expect(unarmed, isA<SelfRelaunchNotArmed>());
    expect(resolutions, 0, reason: 'unarmed apps must not load the library');
  });
}

void _testMissingLibrary() {
  test('diagnosis names an absent bundled worker library for each host', () {
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
        resolveWorker: _unresolvable,
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

  test('default host operations report an absent bundled library', () {
    final directory = Directory.systemTemp.createTempSync(
      'dart_monty_core_self_relaunch_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final status = diagnoseSelfRelaunch(
      executablePath: directory.uri.resolve('bin/application').toFilePath(),
      resolveWorker: _unresolvable,
    );

    expect(status, isA<SelfRelaunchLibraryMissing>());
  });
}

void _testUnloadableLibrary() {
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
}

void _testReadyLibrary() {
  test('diagnosis reports a resolvable worker as ready without its bundle', () {
    expect(
      diagnoseSelfRelaunch(
        executablePath: '/bundle/bin/application',
        fileExists: (_) => false,
        operatingSystem: 'linux',
        resolveWorker: _resolvable,
      ),
      isA<SelfRelaunchReady>(),
    );
  });

  test('availability uses a resolvable worker entry point', () {
    expect(selfRelaunchAvailable(resolveWorker: _resolvable), isTrue);
  });

  test('the default resolver returns a worker diagnosis', () {
    expect(
      diagnoseSelfRelaunch(),
      isNot(isA<SelfRelaunchNotArmed>()),
    );
  });
}

void _testUnrelatedFailure() {
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

(SelfRelaunchStatus, int) _diagnoseUnarmed() {
  var resolutions = 0;
  final status = diagnoseSelfRelaunch(
    resolveWorker: () {
      resolutions++;
      throw ArgumentError('worker symbol is absent');
    },
  );

  return (status, resolutions);
}

void _resolvable() => Object();

void _unresolvable() => throw ArgumentError('worker symbol is absent');

_ChildResult _runResolvableChild() {
  var resolutions = 0;
  var workerMains = 0;
  final exitCodes = <int>[];
  final stderrLines = <String>[];
  runMontyWorkerIfChildWithSeams(
    const [SelfRelaunch.flag],
    exitProcess: exitCodes.add,
    writeStderr: stderrLines.add,
    resolveWorker: () => resolutions++,
    diagnose: ({resolveWorker}) {
      resolveWorker!();

      return const SelfRelaunchReady();
    },
    workerMain: () {
      workerMains++;

      return 23;
    },
  );

  return _ChildResult(exitCodes, stderrLines, resolutions, workerMains);
}

_ChildResult _runFailedChild(SelfRelaunchStatus status) {
  final exitCodes = <int>[];
  final stderrLines = <String>[];
  var workerMains = 0;
  runMontyWorkerIfChildWithSeams(
    const [SelfRelaunch.flag],
    exitProcess: exitCodes.add,
    writeStderr: stderrLines.add,
    resolveWorker: _unexpectedResolver,
    diagnose: ({resolveWorker}) => status,
    workerMain: () {
      workerMains++;

      return 0;
    },
  );

  return _ChildResult(exitCodes, stderrLines, 0, workerMains);
}

bool _runParent() => _runNonWorker(const ['--other']);

bool _runFlagWithExtraArguments() =>
    _runNonWorker(const [SelfRelaunch.flag, 'extra']);

bool _runNonWorker(List<String> args) {
  runMontyWorkerIfChildWithSeams(
    args,
    exitProcess: _unexpectedExit,
    writeStderr: _unexpectedStderr,
    resolveWorker: _unexpectedResolver,
    diagnose: ({resolveWorker}) => throw StateError('unexpected diagnosis'),
    workerMain: _unexpectedWorkerMain,
  );

  return diagnoseSelfRelaunch(resolveWorker: _resolvable) is SelfRelaunchReady;
}

Never _unexpectedExit(int _) => throw StateError('unexpected exit');

Never _unexpectedStderr(String _) => throw StateError('unexpected stderr');

Never _unexpectedResolver() => throw StateError('unexpected resolver');

Never _unexpectedWorkerMain() => throw StateError('unexpected worker main');

final class _ChildResult {
  const _ChildResult(
    this.exitCodes,
    this.stderrLines,
    this.resolutions,
    this.workerMains,
  );

  final List<int> exitCodes;
  final List<String> stderrLines;
  final int resolutions;
  final int workerMains;
}
