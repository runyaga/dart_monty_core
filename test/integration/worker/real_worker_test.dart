// ProcessChannel against the real worker executable (tool/build_worker.sh, or
// the CI artefact), with raw monty-proto requests: there is no driver yet.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi' show Abi;

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

/// Upstream monty-proto 1.1.0's `PROTOCOL_VERSION`.
const _protocolVersion = 5;

/// Every test bounds the worker's memory: an unbounded worker running away
/// was measured at 6 GB in three minutes.
const int _maxMemory = 64 * 1024 * 1024;

pb.ParentRequest _configure({
  int protocolVersion = _protocolVersion,
  int maxMemory = _maxMemory,
}) => pb.ParentRequest(
  configure: pb.Configure(
    scriptName: 'main.py',
    protocolVersion: protocolVersion,
    limits: pb.ResourceLimits(maxMemoryBytes: Int64(maxMemory)),
  ),
);

pb.ParentRequest _feed(String code) => pb.ParentRequest(
  feed: pb.Feed(code: code, cwd: '/'),
);

/// The [MontyCrashedError] that [future] fails with (see
/// process_channel_test.dart for why through the matcher).
Future<MontyCrashedError> _crashOf(Future<Object?> future) async {
  MontyCrashedError? seen;
  await expectLater(
    future,
    throwsA(
      isA<MontyCrashedError>().having((e) => seen = e, 'error', isNotNull),
    ),
  );

  return seen ?? fail('the matcher saw no MontyCrashedError');
}

/// A configured real worker, closed after the test.
Future<ProcessChannel> _configured({int maxMemory = _maxMemory}) async {
  final channel = await ProcessChannel.spawn(await realWorker());
  addTearDown(channel.close);
  final ok = await channel.turn(_configure(maxMemory: maxMemory));
  expect(ok.whichKind(), pb.ChildEvent_Kind.ok);

  return channel;
}

/// The int a `Complete` carries at its root node.
int _completeInt(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete);
  final complete = event.complete;
  final root = complete.values.nodes.elementAtOrNull(complete.value);
  expect(root?.whichKind(), pb.MontyNode_Kind.int_5);

  return root?.int_5.toInt() ?? fail('no root node in $complete');
}

void main() {
  expectNoWorkersLeftAfterEachTest();

  test('locates the built worker for this host', () async {
    final launch = await locateWorker();
    expect(
      launch,
      isA<WorkerExecutable>().having(
        (w) => w.path,
        'path',
        endsWith(workerPackagePath(Abi.current())),
      ),
    );
  });

  test('Configure, Feed 1 + 1, Shutdown', () async {
    final channel = await _configured();
    expect(_completeInt(await channel.turn(_feed('1 + 1'))), 2);
    await channel.close();
    expect(await channel.exitCode, 0);
  });

  test('prints stream to onPrint before the turn ends', () async {
    final channel = await _configured();
    final text = StringBuffer();
    final end = await channel.turn(
      _feed('print("hello")\n3'),
      onPrint: (print) => text.writeAll([
        for (final segment in print.segments) segment.text,
      ]),
    );
    expect(text.toString(), 'hello\n');
    expect(_completeInt(end), 3);
  });

  test('a Python exception is in-band; the worker survives', () async {
    final channel = await _configured();
    final end = await channel.turn(_feed('1 / 0'));
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(channel.isAlive, isTrue);
    expect(_completeInt(await channel.turn(_feed('2 + 2'))), 4);
  });

  test('max_memory inside the interpreter is in-band MemoryError', () async {
    final channel = await _configured(maxMemory: 16 * 1024 * 1024);
    final end = await channel.turn(
      _feed('x = []\nwhile True:\n    x.append("a" * 100000)'),
    );
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(end.error.toString(), contains('MemoryError'));
    expect(channel.isAlive, isTrue);
  });

  test('protocol version skew: FatalError, exit 4', () async {
    final channel = await ProcessChannel.spawn(await realWorker());
    addTearDown(channel.close);
    final crash = await _crashOf(
      channel.turn(_configure(protocolVersion: 999)),
    );
    expect(crash.cause, CrashCause.fatal);
    expect(crash.exitCode, 4);
    expect(crash.message, contains('999'));
  });

  test('deadline kill, then a fresh worker answers', () async {
    final channel = await _configured();
    final turn = channel.turn(_feed('while True:\n    pass'));
    Timer(const Duration(milliseconds: 300), channel.kill);
    final crash = await _crashOf(turn);
    expect(crash.cause, CrashCause.killed);
    expect(channel.isAlive, isFalse);

    // Recovery is a new channel; the dead one is never reused.
    final fresh = await ProcessChannel.spawn(await realWorker());
    addTearDown(fresh.close);
    await fresh.turn(_configure());
    expect(_completeInt(await fresh.turn(_feed('1 + 1'))), 2);
  });
}
