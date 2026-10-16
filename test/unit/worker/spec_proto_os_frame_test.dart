// Exercise the OS automatic-answer size refusal with the scripted channel's
// smaller cap. The production cap is independently pinned to 256 MiB.
import 'package:dart_monty_core/dart_monty_core.dart' hide Frame;
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'oversized OS answer is refused before transmission',
    () async {
      expect(Frame.maxLength, 268435456);
      final (session, channel) = await protoConfiguredSession([
        answer([
          pb.ChildEvent(
            osCall: pb.OsCall(callId: 7, dateTimeNow: pb.OsCall_DateTimeNow()),
          ),
        ]),
      ], frameLimit: 256);
      // 300 ASCII bytes + string field 3 + node envelope 3 + node_count 2
      // + arena envelope 3 + result 4 + call_id 2 + request envelope 3.
      await expectLater(
        session.feedRun('clock()', os: (_, _, _) => MontyString('x' * 300)),
        throwsA(
          protoRuntime(
            'RuntimeError',
            'request frame of 320 bytes exceeds the maximum of 256 bytes',
          ),
        ),
      );
      final onlyConfigureAndFeed = hasLength(2);
      expect(channel.requests, onlyConfigureAndFeed);
      expect(channel.isAlive, isTrue);
      await expectLater(session.feedRun('42'), throwsStateError);
      expect(channel.requests, onlyConfigureAndFeed);
    },
  );
}
