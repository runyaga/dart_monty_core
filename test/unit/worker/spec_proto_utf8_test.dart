// Raw worker bytes exercise the decoder and then the public session lifetime.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

final class _Port implements WorkerPort {
  final posted = StreamController<Uint8List>();
  int terminations = 0;
  int acknowledged = 0;

  @override
  void acknowledge(int bytes) => acknowledged += bytes;

  @override
  void post(Uint8List frame) => posted.add(frame);

  @override
  void terminate() => terminations++;
}

Future<void> _request(
  StreamIterator<Uint8List> requests,
  pb.ParentRequest_Kind kind,
) async {
  expect(await requests.moveNext(), isTrue);
  final body = Frame.split(requests.current).singleOrNull ?? fail('no request');
  expect(pb.ParentRequest.fromBuffer(body).whichKind(), kind);
}

void main() {
  test(
    'malformed UTF-8 discards worker '
    'and invalidates session',
    () async {
      final port = _Port();
      final requests = StreamIterator(port.posted.stream);
      addTearDown(port.posted.close);
      addTearDown(requests.cancel);
      final connection = WorkerConnection.accept(port, (
        ready: true,
        error: null,
        jspi: true,
        protocol: workerProtocolVersion,
        events: null,
        outcome: null,
        trap: null,
        print: null,
        stderr: null,
      ));
      final pool = await startMonty(
        const PoolOptions(minProcesses: 0, maxProcesses: 1),
        open: () => PendingSpawn((_) async => connection),
      );
      addTearDown(pool.close);
      final checkout = pool.checkout();
      await _request(requests, pb.ParentRequest_Kind.configure);
      connection.onReply(Frame.encode(ok()), outcomeContinue);
      final session = await checkout;
      addTearDown(session.close);
      final failed = expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: failed to decode Protobuf message: '
            'MontyNode.kind: Complete.values: ChildEvent.kind: '
            'invalid string value: data is not UTF-8 encoded',
          ),
        ),
      );
      await _request(requests, pb.ParentRequest_Kind.feed);
      // Complete -> Arena -> str with invalid UTF-8 C3 28.
      connection.onReply(
        Frame.wrap([
          0x32,
          8,
          0x12,
          6,
          0x12,
          4,
          0x42,
          2,
          0xc3,
          0x28,
        ]),
        outcomeContinue,
      );
      await failed;
      expect(port.terminations, 1);
      expect(connection.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
      await expectLater(session.feedStart('42'), throwsStateError);
      await expectLater(session.dump(), throwsStateError);
    },
  );
}
