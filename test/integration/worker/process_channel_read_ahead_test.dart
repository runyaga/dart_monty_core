// Control stdout chunk boundaries on the real ProcessChannel. The 4 MiB
// expectation comes from the spec, not ProcessChannel.readAheadLimit.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../unit/worker/_scripted_channel.dart';

const int _fourMiB = 4 * 1024 * 1024;

void main() {
  for (final run in [1, 2, 3]) {
    test(
      'completed frames one byte below and above 4 MiB (run $run)',
      () async {
        for (final extra in [-1, 1]) {
          final (session, process) = await _session();
          final text = 'a' * (_fourMiB - 21 + extra);
          final frame = _printFrame(text);
          expect(frame.length, _fourMiB + extra);
          process.output.add(frame);
          // Exact-boundary behaviour at 4 MiB is not asserted.
          _expectPaused(process, extra > 0, '4 MiB + $extra byte(s)');
          final received = <String>[];
          expect(
            await session.feedRun(
              'None',
              printCallback: (_, value) => received.add(value),
            ),
            const MontyNone(),
          );
          expect(received, [text]);
          _expectPaused(process, false, 'drained below 4 MiB');
        }
      },
    );
  }
  test(
    'pause above 4 MiB after the in-flight frame ends',
    () async {
      final (session, process) = await _session();
      final texts = _fill(process, inFlight: true);
      final received = <String>[];
      expect(
        await session.feedRun(
          'None',
          printCallback: (_, text) => received.add(text),
        ),
        const MontyNone(),
      );
      expect(received, texts);
    },
  );
  test(
    'completed frames pause immediately above 4 MiB',
    () async {
      final (session, process) = await _session();
      final texts = _fill(process);
      final received = <String>[];
      expect(
        await session.feedRun(
          'None',
          printCallback: (_, text) => received.add(text),
        ),
        const MontyNone(),
      );
      expect(received, texts);
    },
  );
  for (final run in [1, 2]) {
    test(
      'frames between turns stay bounded and reach the next turn (run $run)',
      () async {
        final (session, process) = await _session();
        expect(await session.feedRun('None'), const MontyNone());
        final texts = _fill(process);
        final received = <String>[];
        expect(
          await session.feedRun(
            'None',
            printCallback: (_, text) => received.add(text),
          ),
          const MontyNone(),
        );
        expect(received, texts);
      },
    );
    test(
      'a held snapshot retains bounded frames for its resume (run $run)',
      () async {
        final (session, process) = await _session(suspend: true);
        final received = <String>[];
        final snapshot =
            await session.feedStart(
                  'f()',
                  printCallback: (_, text) => received.add(text),
                )
                as FunctionSnapshot;
        final texts = _fill(process);
        expect(received, isEmpty);
        final result = await snapshot.resume(
          const ExternalReturnValue(MontyNone()),
        );
        expect((result as MontyComplete).output, const MontyNone());
        expect(received, texts);
      },
    );
    test(
      'read-ahead stays bounded during a stalled print callback (run $run)',
      () async {
        final (session, process) = await _session(stall: true);
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final received = <String>[];
        final turn = session.feedRun(
          'print("start")',
          printCallback: (_, text) async {
            received.add(text);
            if (text == 'start') {
              entered.complete();
              await release.future;
            }
          },
        );
        await entered.future;
        final texts = _fill(process);
        process.output.add(wire.Frame.encode(completeNone()));
        expect(received, ['start']);
        release.complete();
        expect(await turn, const MontyNone());
        expect(received, ['start', ...texts]);
      },
    );
  }
}

/// Below the boundary, then above it with a partially received large frame.
/// StreamController's synchronous delivery makes pause observable without
/// sleeping or reading the channel's private queue.
List<String> _fill(_ControlledProcess process, {bool inFlight = false}) {
  final firstText = 'a' * (_fourMiB - 22);
  final first = _printFrame(firstText);
  expect(first.length, _fourMiB - 1);
  process.output.add(first);
  _expectPaused(process, false, 'below 4 MiB');
  if (!inFlight) {
    process.output.add(_printFrame('crossing'));
    _expectPaused(process, true, 'completed frames above 4 MiB');

    return [firstText, 'crossing'];
  }
  final bigText = 'b' * (5 * 1024 * 1024);
  final big = _printFrame(bigText);
  process.output.add([..._printFrame('crossing'), ...big.take(8)]);
  _expectPaused(process, false, 'finish the started frame');
  process.output.add(big.sublist(8));
  _expectPaused(process, true, 'above 4 MiB, at a boundary');

  return [firstText, 'crossing', bigText];
}

void _expectPaused(_ControlledProcess process, bool paused, String reason) {
  expect(process.output.isPaused, paused, reason: reason);
}

List<int> _printFrame(String text) => wire.Frame.encode(
  printed([(pb.PrintStream.PRINT_STREAM_STDOUT, text)]),
);

Future<(MontySession, _ControlledProcess)> _session({
  bool suspend = false,
  bool stall = false,
}) async {
  final process = _ControlledProcess(suspend: suspend, stall: stall);
  addTearDown(process.dispose);
  final channel = processChannelForTesting(process);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);

  return (session, process);
}

final class _ControlledProcess implements Process {
  _ControlledProcess({required this.suspend, required this.stall}) {
    _input.stream.listen(_answer);
    stdin = IOSink(_input.sink);
  }

  final bool suspend;
  final bool stall;
  final output = StreamController<List<int>>(sync: true);
  @override
  late final IOSink stdin;
  final _input = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _decoder = wire.FrameDecoder();

  Future<void> dispose() async {
    kill();
    await stdin.close();
    await _input.close();
    await output.close();
    _decoder.close();
  }

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    unawaited(output.close());

    return true;
  }

  void _answer(List<int> bytes) {
    for (final body in _decoder.add(bytes)) {
      final request = pb.ParentRequest.fromBuffer(body);
      final kind = request.whichKind();
      final event = switch (kind) {
        pb.ParentRequest_Kind.feed when suspend => pb.ChildEvent(
          functionCall: pb.FunctionCall(functionName: 'f', callId: 1),
        ),
        pb.ParentRequest_Kind.feed when stall => printed([
          (pb.PrintStream.PRINT_STREAM_STDOUT, 'start'),
        ]),
        pb.ParentRequest_Kind.feed ||
        pb.ParentRequest_Kind.resumeCall => completeNone(),
        _ => ok(),
      };
      output.add(wire.Frame.encode(event));
      if (kind == pb.ParentRequest_Kind.shutdown) kill();
    }
  }
}
