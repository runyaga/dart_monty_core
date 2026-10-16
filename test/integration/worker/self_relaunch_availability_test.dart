// Keep the arming and resolution checks inside the measured test isolate.
// Other suites can load the mount dylib process-wide, so simulate absence
// only at symbol resolution; real absence is checked by the unbundled probe.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart' show MontyCrashedError;
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

    final unarmed = selfRelaunchAvailable(resolveWorker: missingWorker);
    expect(unarmed, isFalse);
    expect(resolutions, 0, reason: 'unarmed apps must not load the library');
    runMontyWorkerIfChild(const ['--other']);
    final armedWithoutWorker = selfRelaunchAvailable(
      resolveWorker: missingWorker,
    );
    expect(armedWithoutWorker, isFalse);
    expect(resolutions, 1);
    await expectLater(
      locateWorker(
        isAot: true,
        canSelfRelaunch: () =>
            selfRelaunchAvailable(resolveWorker: missingWorker),
      ),
      throwsA(isA<MontyCrashedError>()),
    );

    var resolved = 0;
    void resolvable() => resolved++;
    expect(selfRelaunchAvailable(resolveWorker: resolvable), isTrue);
    expect(
      await locateWorker(
        isAot: true,
        canSelfRelaunch: () => selfRelaunchAvailable(resolveWorker: resolvable),
      ),
      isA<SelfRelaunch>(),
    );
    expect(resolved, 2);
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
