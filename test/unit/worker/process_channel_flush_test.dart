// Drive the real channel with independently controlled stdout, stdin and exit.
@TestOn('vm')
@Tags(['vm-only'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:test/test.dart';

import '../telemetry/recording_adapter.dart';

final _request = pb.ParentRequest(feed: pb.Feed(code: '42'));
final _complete = pb.ChildEvent(complete: pb.Complete());

Matcher get _vanishedWhileSending => isA<MontyCrashedError>()
    .having((error) => error.cause, 'cause', CrashCause.vanished)
    .having((error) => error.context, 'context', sendingRequest);

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  late _TestProcess process;
  late ProcessChannel channel;

  setUp(() {
    process = _TestProcess();
    channel = processChannelForTesting(process);
    addTearDown(() async {
      channel.kill();
      final flushed = process.stdin.flushed;
      if (!flushed.isCompleted) flushed.complete();
      await channel.close();
      await process.dispose();
      expect(ProcessChannel.live, isNot(contains(channel)));
    });
  });

  for (final succeeds in [true, false]) {
    test('complete waits for a later flush: success=$succeeds', () async {
      var ended = false;
      final turn = channel.turn(_request).whenComplete(() => ended = true);
      final checked = expectLater(
        turn,
        succeeds ? completion(_complete) : throwsA(_vanishedWhileSending),
      );
      await process.stdin.flushing.future;
      expect(process.stdin.frames, [Frame.encode(_request)]);
      process.output.add(Frame.encode(_complete));
      // Drain microtasks after synchronous frame delivery; no OS or timer race.
      await Future<void>.delayed(Duration.zero);
      expect(channel.readAhead.now, 0);
      expect(ended, isFalse);
      await expectLater(channel.turn(_request), throwsStateError);

      if (succeeds) {
        process.stdin.flushed.complete();
      } else {
        process.stdin.flushed.completeError(
          const SocketException('Broken pipe'),
          StackTrace.current,
        );
        process.exit.complete(0);
      }
      await checked;
      expect(ended, isTrue);
      final records = measurements(adapter, 'wire.frame.bytes');
      expect(
        records
            .where((m) => m.attributes['direction'] == 'sent')
            .map((m) => m.value),
        succeeds ? process.stdin.frames.map((frame) => frame.length) : isEmpty,
      );
      expect(
        records
            .where((m) => m.attributes['direction'] == 'received')
            .map((m) => m.value),
        [Frame.encode(_complete).length],
      );
    });
  }

  test(
    'native frame bytes preserve noncanonical payload and its header',
    () async {
      final body = _complete.writeToBuffer();
      final reply = Frame.wrap([0xa0, 1, 1, 0xa0, 1, 2, ...body]);
      final turn = channel.turn(_request);
      await process.stdin.flushing.future;
      process.stdin.flushed.complete();
      process.output.add(reply);
      await turn;
      expect(
        measurements(adapter, 'wire.frame.bytes')
            .where((m) => m.attributes['direction'] == 'received')
            .map((m) => m.value),
        [reply.length],
      );
    },
  );

  test('exit cannot turn a pending flush into a successful send', () async {
    var ended = false;
    final turn = channel.turn(_request).whenComplete(() => ended = true);
    final checked = expectLater(turn, throwsA(_vanishedWhileSending));
    await process.stdin.flushing.future;
    process.output.add(Frame.encode(_complete));
    await Future<void>.delayed(Duration.zero);
    expect(channel.readAhead.now, 0);
    expect(ended, isFalse);
    process.exit.complete(0);
    // Model Process's exit handler destroying stdin before EPIPE is delivered.
    await Future<void>.delayed(Duration.zero);
    process.stdin.flushed.complete();
    await checked;
  });

  test('a flushed request keeps its completion after worker exit', () async {
    final turn = channel.turn(_request);
    final checked = expectLater(turn, completion(_complete));
    await process.stdin.flushing.future;
    process.stdin.flushed.complete();
    await Future<void>.delayed(Duration.zero);
    process.exit.complete(0);
    process.output.add(Frame.encode(_complete));
    await checked;
  });

  test('flush immediately before exit still confirms the send', () async {
    final turn = channel.turn(_request);
    final checked = expectLater(turn, completion(_complete));
    await process.stdin.flushing.future;
    process.output.add(Frame.encode(_complete));
    process.stdin.flushed.complete();
    process.exit.complete(0);
    await checked;
  });
}

final class _DelayedSink implements IOSink {
  final frames = <List<int>>[];
  final flushing = Completer<void>();
  final flushed = Completer<void>();

  @override
  Future<void> get done => Future.value();

  @override
  void add(List<int> data) => frames.add(data);

  @override
  Future<void> flush() {
    flushing.complete();

    return flushed.future;
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected IOSink call: ${invocation.memberName}',
  );
}

final class _TestProcess implements Process {
  final output = StreamController<List<int>>(sync: true);
  final exit = Completer<int>();

  @override
  // The fake sink only records writes and flushes; it has nothing to close.
  // ignore: dispose-class-fields
  final _DelayedSink stdin = _DelayedSink();

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => exit.future;

  Future<void> dispose() async {
    await output.close();
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(0);

    return true;
  }
}
