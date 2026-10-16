// Native default print selection is per feed, even after a collector.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

final class _CapturedStdout implements Stdout {
  final written = StringBuffer();

  @override
  IOSink get nonBlocking => this;

  @override
  void write(Object? object) => written.write(object);

  @override
  Future<void> flush() => Future.value();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _selection(bool start) async {
  final worker = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(maxProcesses: 1, workerLocation: worker.path);
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);
  final collector = CollectString();
  final sink = _CapturedStdout();
  await IOOverrides.runZoned(() async {
    if (start) {
      await session.feedStart(
        'print("first", end="")',
        printCallback: collector.call,
      );
      final done =
          await session.feedStart('print("second", end="")') as MontyComplete;
      expect(done.output, const MontyNone());
    } else {
      await session.feedRun(
        'print("first", end="")',
        printCallback: collector.call,
      );
      expect(
        await session.feedRun('print("second", end="")'),
        const MontyNone(),
      );
    }
  }, stdout: () => sink);
  expect(collector.output, 'first');
  expect(sink.written.toString(), 'second');
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  for (final start in [false, true]) {
    test(
      'REQ-print-delivery-3: omission resets native sink (start=$start)',
      () => _selection(start),
    );
  }
}
