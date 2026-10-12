// Where the worker executable is looked for, and what is said when it is not
// there.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:ffi' show Abi;

import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
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
    test('an explicit launch wins', () async {
      const explicit = WorkerExecutable('/opt/monty', args: ['subprocess']);
      expect(await locateWorker(explicit: explicit), same(explicit));
    });

    test('none built: StateError naming the path and the fix', () async {
      await expectLater(
        locateWorker(abi: Abi.fuchsiaRiscv64),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('src/bin/fuchsia-riscv64/dart_monty_worker'),
              contains('tool/build_worker.sh'),
            ),
          ),
        ),
      );
    });
  });
}
