// A failed real-worker dump keeps its suspended feed and mount overlay.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_b2_support.dart';
import '_worker_harness.dart';

Future<FunctionSnapshot> _hostCall(MontySnapshot snapshot) async {
  var current = snapshot;
  while (current is FunctionSnapshot && current.isOsFunction) {
    current = await current.resumeAuto();
  }
  final call = current as FunctionSnapshot;
  expect(call.functionName, 'f');

  return call;
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'REQ-wire-limits-40: failed suspended dump retains call and feed mount',
    () async {
      final directory = Directory.systemTemp.createTempSync('pool-dump-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final hostFile = File('${directory.path}/value')
        ..writeAsStringSync('host');
      final mount = MountDir(hostPath: directory.path, virtualPath: '/data');
      addTearDown(mount.close);
      final location = await realWorker() as WorkerExecutable;
      final pool = await Monty.start(
        maxProcesses: 1,
        workerLocation: location.path,
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        limits: const ResourceLimits(maxMemory: 1024 * 1024 * 1024),
      );
      addTearDown(session.close);
      final call = await _hostCall(
        await session.feedStart(
          '''
from pathlib import Path
Path('/data/value').write_text('overlay')
large = b'x' * 268435457
f()
Path('/data/value').read_text()
''',
          mount: [mount],
        ),
      );
      await expectLater(
        call.dump(),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'RuntimeError')
              .having(
                (e) => e.exception.message,
                'message',
                matches(
                  r'^result frame of \d+ bytes exceeds the maximum of 268435456 bytes$',
                ),
              ),
        ),
      );
      await expectLater(session.feedRun('1'), poolB2Pending);
      var resumed = await call.resume(const ExternalReturnValue(MontyNone()));
      while (resumed is FunctionSnapshot) {
        resumed = await resumed.resumeAuto();
      }
      expect((resumed as MontyComplete).output, const MontyString('overlay'));
      expect(hostFile.readAsStringSync(), 'host');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
