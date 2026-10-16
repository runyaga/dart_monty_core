// Protocol fixtures extend the existing pool fixtures without changing them.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_pool_support.dart';
import '_scripted_channel.dart';

const poolB2Answer = ExternalReturnValue(MontyNone());
final Matcher poolB2Pending = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    'feed called while a suspension is awaiting an answer',
  ),
);
final Matcher poolB2Oversized = throwsA(
  isA<MontyRuntimeError>()
      .having((e) => e.exception.excType, 'type', 'RuntimeError')
      .having(
        (e) => e.exception.message,
        'message',
        matches(
          r'^request frame of \d+ bytes exceeds the maximum of 64 bytes$',
        ),
      ),
);

Future<(MontySession, ScriptedChannel)> poolB2Session(
  List<Reply> replies, {
  SessionConfig config = const SessionConfig(),
  PoolOptions options = const PoolOptions(minProcesses: 0, maxProcesses: 1),
  int frameLimit = 268435456,
}) async {
  final channel = ScriptedChannel([
    configurePool,
    ...replies,
    resetPool,
  ], frameLimit: frameLimit);
  final pool = await poolWith([channel], options: options);
  final session = await pool.checkoutWith(config);
  addTearDown(session.close);

  return (session, channel);
}

pb.ChildEvent poolB2Futures([List<int> ids = const [1]]) => pb.ChildEvent(
  resolveFutures: pb.ResolveFutures(pendingCallIds: ids),
);

pb.ChildEvent poolB2Sleep(double seconds, {bool asynchronous = false}) =>
    pb.ChildEvent(
      osCall: asynchronous
          ? pb.OsCall(
              callId: 1,
              asyncSystemSleep: pb.OsCall_AsyncSleep(delay: seconds),
            )
          : pb.OsCall(
              callId: 1,
              systemSleep: pb.OsCall_Sleep(seconds: seconds),
            ),
    );

/// Echo the independently asserted AbortFeed exception, like the worker does.
List<pb.ChildEvent> poolB2Abort(pb.ParentRequest request) {
  expect(request.whichKind(), pb.ParentRequest_Kind.abortFeed);

  return [
    pb.ChildEvent(error: pb.Error(exception: request.abortFeed.exception)),
  ];
}
