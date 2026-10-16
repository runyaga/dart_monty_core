// Keep the arming and resolution checks inside the measured test isolate.
// Other suites can load the mount dylib process-wide, so simulate absence
// only at symbol resolution; real absence is checked by the unbundled probe.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:test/test.dart';

void main() {
  test('self-relaunch requires arming and a resolvable worker', () async {
    var resolutions = 0;
    void missingWorker() {
      resolutions++;
      throw ArgumentError('worker symbol is absent');
    }

    expect(selfRelaunchAvailable(resolveWorker: missingWorker), isFalse);
    expect(resolutions, 0, reason: 'unarmed apps must not load the library');
    runMontyWorkerIfChild(const ['--other']);
    expect(selfRelaunchAvailable(resolveWorker: missingWorker), isFalse);
    expect(resolutions, 1);
    await expectLater(
      locateWorker(
        isAot: true,
        canSelfRelaunch: () =>
            selfRelaunchAvailable(resolveWorker: missingWorker),
      ),
      throwsA(isA<MontyCrashedError>()),
    );

    // Deliberately load the real library, so success is independent of the
    // order in which other test isolates happen to open mounts.
    final directory = Directory.systemTemp.createTempSync('self-relaunch-');
    addTearDown(directory.deleteSync);
    MountDir(hostPath: directory.path, virtualPath: '/mnt').close();
    expect(selfRelaunchAvailable(), isTrue);
    expect(await locateWorker(isAot: true), isA<SelfRelaunch>());
  });

  test('self-relaunch does not hide unrelated resolver failures', () {
    runMontyWorkerIfChild(const []);
    final failure = StateError('resolver failed');
    expect(
      () => selfRelaunchAvailable(resolveWorker: () => throw failure),
      throwsA(same(failure)),
    );
  });
}
