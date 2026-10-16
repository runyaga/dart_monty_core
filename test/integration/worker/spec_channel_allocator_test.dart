// Hard-limit operations have no interpreter checkpoint. A real child must
// exit with allocator status 65, rather than return a soft MemoryError.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Future<ProcessChannel> _channel({
  bool typeCheck = false,
  int maxMemory = 1000000,
}) async {
  final channel = await ProcessChannel.spawn(await locateWorker());
  addTearDown(channel.close);
  final event = await channel.turn(
    pb.ParentRequest(
      configure: pb.Configure(
        protocolVersion: workerProtocolVersion,
        scriptName: 'allocator.py',
        typeCheck: typeCheck,
        limits: pb.ResourceLimits(maxMemoryBytes: Int64(maxMemory)),
      ),
    ),
  );
  expect(event.whichKind(), pb.ChildEvent_Kind.ok);

  return channel;
}

Future<void> _terminated(
  ProcessChannel channel,
  pb.ParentRequest request,
) async {
  await expectLater(
    channel.turn(request),
    throwsA(
      isA<MontyCrashedError>()
          .having((error) => error.exitStatus, 'exit status', 65)
          .having(
            (error) => error.toString(),
            'message',
            'monty worker crashed while waiting for a reply '
                '(exit status: 65)',
          ),
    ),
  );
  expect(await channel.exitCode, 65);
  expect(channel.isAlive, isFalse);
}

void main() {
  test(
    'REQ-budgets-and-limits-22: request framing crosses the hard ceiling',
    () async {
      final channel = await _channel();
      await _terminated(
        channel,
        pb.ParentRequest(feed: pb.Feed(code: '#' * 5000000)),
      );
    },
  );

  test(
    'REQ-budgets-and-limits-22: input decoding crosses the hard ceiling',
    () async {
      final channel = await _channel();
      await _terminated(
        channel,
        pb.ParentRequest(
          feed: pb.Feed(
            code: 'None',
            values: pb.Arena(
              nodeCount: 100000,
              nodes: List.generate(
                100000,
                (_) => pb.MontyNode(none: pb.Unit()),
              ),
            ),
          ),
        ),
      );
    },
  );

  test(
    'REQ-budgets-and-limits-22: snapshot loading crosses the hard ceiling',
    () async {
      final pool = await Monty.start(maxProcesses: 1);
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      expect(await session.feedRun('x = [None] * 400000'), const MontyNone());
      final dump = await session.dump();
      expect(dump.length, lessThan(1000000));
      final channel = await _channel();
      await _terminated(channel, pb.ParentRequest(load: pb.Load(state: dump)));
    },
  );

  test(
    'REQ-budgets-and-limits-22: type checking crosses the hard ceiling',
    () async {
      const limit = 32 * 1024 * 1024;
      final control = await _channel(maxMemory: limit);
      final channel = await _channel(typeCheck: true, maxMemory: limit);
      final code = List.generate(
        30000,
        (index) => 'x$index: int = $index',
      ).join('\n');
      final request = pb.ParentRequest(feed: pb.Feed(code: code));
      // The identical frame, source and interpreter work fit this cap when
      // type checking is off. The extra checking work crosses the ceiling.
      final accepted = await control.turn(request);
      expect(accepted.whichKind(), pb.ChildEvent_Kind.complete);
      expect(control.isAlive, isTrue);
      await _terminated(channel, request);
    },
  );
}
