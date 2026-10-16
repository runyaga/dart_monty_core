// Check callback reentrancy outside the handler, where a host-answer error
// cannot swallow the assertion or leave the test waiting for a signal.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_support.dart';

Future<Object> _outcome(Future<MontyValue> work) async {
  try {
    return await work;
  } on Object catch (error) {
    return error;
  }
}

void main() {
  test(
    'REQ-session-turns-4: OS callback can await its own session dump',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolOs()]),
        expecting(pb.ParentRequest_Kind.dump, [
          pb.ChildEvent(dumpResult: pb.DumpResult(state: [4, 5, 6])),
        ]),
        answer([
          complete([intNode(42)]),
        ]),
        resetPool,
      ]);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      addTearDown(session.close);
      List<int>? dumped;
      final outcome = _outcome(
        session.feedRun(
          'read',
          os: (name, args, kwargs) async {
            dumped = await session.dump();

            return const MontyString('text');
          },
        ),
      );
      await pumpEventQueue();
      // A turn lock held across the OS callback leaves this null. Assert here,
      // outside host dispatch, before awaiting a potentially deadlocked drive.
      expect(dumped, [4, 5, 6]);
      expect(await outcome, const MontyInt(42));
      expect(channel.requests.map((request) => request.whichKind()), [
        pb.ParentRequest_Kind.configure,
        pb.ParentRequest_Kind.feed,
        pb.ParentRequest_Kind.dump,
        pb.ParentRequest_Kind.resumeCall,
      ]);
      expect(channel.kills, 0);
    },
  );
}
