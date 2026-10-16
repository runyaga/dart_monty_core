// Native default printing awaits both stream flushes, including stderr.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

final class _HeldStdout implements Stdout {
  final written = StringBuffer();
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  IOSink get nonBlocking => this;

  @override
  void write(Object? object) => written.write(object);

  @override
  Future<void> flush() {
    if (!entered.isCompleted) entered.complete();

    return release.future;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  for (final stream in ['stdout', 'stderr']) {
    test(
      'REQ-platforms-21: default $stream delivery awaits its flush',
      () async {
        final location = await realWorker() as WorkerExecutable;
        final pool = await Monty.start(
          maxProcesses: 1,
          workerLocation: location.path,
        );
        addTearDown(pool.close);
        final session = await pool.checkout();
        addTearDown(session.close);
        final sink = _HeldStdout();
        addTearDown(() {
          if (!sink.release.isCompleted) sink.release.complete();
        });
        var completed = false;
        final running = IOOverrides.runZoned(
          () async {
            final result = await session.feedRun(
              'import sys\n'
              'print("fragment-é", end="", file=sys.$stream, flush=True)\n42',
            );
            completed = true;

            return result;
          },
          stdout: stream == 'stdout' ? () => sink : null,
          stderr: stream == 'stderr' ? () => sink : null,
        );
        await sink.entered.future;
        await pumpEventQueue();
        expect(sink.written.toString(), 'fragment-é');
        expect(completed, isFalse);
        sink.release.complete();
        expect(await running, const MontyInt(42));
      },
    );
  }
}
