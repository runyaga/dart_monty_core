// Rejected payloads and interruption at the public session boundary.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_arena_fixtures.dart' as arena;
import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'class type key loses the session',
    () async {
      final (session, channel) = await protoConfiguredSession([
        answer([
          complete([
            arena.classType('P', id: arena.uuid(1)),
            arena.dict([(0, 0)]),
          ]),
        ]),
      ]);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: TypeError: unhashable '
            "type: 'MontyClassTypeProxy'",
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );

  test(
    'recorded print failure wins over busy close',
    () async {
      final recorded = Completer<void>();
      final (session, channel) = await protoConfiguredSession([
        hangAfter([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'x')]),
        ]),
      ]);
      final run = session.feedRun(
        'print("x")',
        printCallback: (_, _) {
          // The next event-loop turn follows recording the print failure.
          Timer.run(recorded.complete);
          throw const ExternalException('ValueError', 'print refused');
        },
      );
      final assertion = expectLater(
        run,
        throwsA(protoRuntime('ValueError', 'print refused')),
      );
      await recorded.future;
      await session.close();
      await assertion;
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );

  test(
    'TypingError after Load ends the session',
    () async {
      final (session, channel) = await protoConfiguredSession([
        expecting(pb.ParentRequest_Kind.load, [
          pb.ChildEvent(
            typingError: pb.TypingError(diagnostics: 'bad restored code'),
          ),
        ]),
      ]);
      // The requirement specifies termination, not the classification of this
      // unexpected Load response (only feed turns can normally type-check).
      await expectLater(
        session.loadSession(Uint8List.fromList([1])),
        throwsA(
          protoCrash('unexpected reply to Load: typingError'),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );

  test(
    'oversized resume is claimed before asynchronous send',
    () async {
      final (session, channel) = await protoConfiguredSession([
        answer([protoCall()]),
      ], frameLimit: 256);
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      final first = snapshot.resume(
        ExternalReturnValue(MontyString('x' * 300)),
      );
      // The snapshot is claimed synchronously, before any send completes.
      expect(
        () => snapshot.resume(const ExternalReturnValue(MontyInt(1))),
        throwsStateError,
      );
      await expectLater(
        first,
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.excType,
            'type',
            'RuntimeError',
          ),
        ),
      );
      // The failed send still claimed the snapshot, so it cannot be retried.
      expect(
        () => snapshot.resume(const ExternalReturnValue(MontyInt(1))),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                'snapshot has already been resumed',
              )
              .having(
                (e) => e.toString(),
                'rendered error',
                'Bad state: snapshot has already been resumed',
              ),
        ),
      );
      expect(channel.requests, hasLength(2));
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );
}
