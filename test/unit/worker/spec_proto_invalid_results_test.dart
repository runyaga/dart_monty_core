// Malformed dates, cyclic manual answers and failed loads at the boundary.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'invalid worker date discards worker and session',
    () async {
      final (session, channel) = await protoSession([
        answer([
          complete([
            pb.MontyNode(date: pb.Date(year: 2026, month: 13, day: 1)),
          ]),
        ]),
      ]);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: invalid value for Date.month: '
            '13 is outside the range 1..=12',
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
      expect(channel.requests, hasLength(2));
    },
  );

  test(
    'cyclic manual answer sends nothing and permits retry',
    () async {
      final (session, channel) = await protoSession([
        answer([protoCall()]),
        answer([protoInt(7)]),
        answer([protoInt(42)]),
      ]);
      final items = <MontyValue>[];
      final cyclic = MontyList(items);
      items.add(cyclic);
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      expect(
        () => snapshot.resume(ExternalReturnValue(cyclic)),
        throwsA(protoRuntime('ValueError', 'Circular reference detected')),
      );
      expect(channel.requests, hasLength(2));
      final done = await snapshot.resume(
        const ExternalReturnValue(MontyInt(7)),
      );
      expect((done as MontyComplete).output, const MontyInt(7));
      expect(await session.feedRun('42'), const MontyInt(42));
      expect(channel.requests, hasLength(4));
    },
  );

  for (final snapshot in [false, true]) {
    test(
      'TypingError discards load snapshot=$snapshot',
      () async {
        final (session, channel) = await protoConfiguredSession([
          expecting(pb.ParentRequest_Kind.load, [
            pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'bad code')),
          ]),
        ]);
        final bytes = Uint8List.fromList([1]);
        await expectLater(
          snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
          throwsA(protoCrash('unexpected reply to Load: typingError')),
        );
        expect(channel.isAlive, isFalse);
        await expectLater(session.feedRun('42'), throwsStateError);
        expect(channel.requests, hasLength(2));
      },
    );
  }
}
