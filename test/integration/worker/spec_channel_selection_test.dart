@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:test/test.dart';

void main() {
  test('REQ-runMontyWorkerIfChild-14: explicit launch wins in AOT', () async {
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

  test(
    'REQ-runMontyWorkerIfChild-16: JIT never asks self-relaunch eligibility',
    () async {
      runMontyWorkerIfChild(const []);
      expect(selfRelaunchAvailable(resolveWorker: _resolved), isFalse);
      var eligibilityChecks = 0;
      final launch = await locateWorker(
        resolvePackageUri: (_) async => Uri.file(Platform.resolvedExecutable),
        canSelfRelaunch: () {
          eligibilityChecks++;

          return true;
        },
      );
      expect((launch as WorkerExecutable).path, Platform.resolvedExecutable);
      expect(eligibilityChecks, 0);
    },
  );
}

void _resolved() => _resolutions++;
int _resolutions = 0;
