// Spec contracts at the session boundary, over wire-encoded scripted replies.
// These tests run unchanged on VM, dart2js and dart2wasm.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'a syntax failure leaves the session usable',
    () async {
      final (session, channel) = await protoSession([
        answer([raised('SyntaxError', 'invalid syntax')]),
        answer([protoInt(42)]),
      ]);
      await expectLater(
        session.feedRun('if'),
        throwsA(
          isA<MontySyntaxError>()
              .having((e) => e.exception.excType, 'type', 'SyntaxError')
              .having((e) => e.toString(), 'message', 'invalid syntax'),
        ),
      );
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
      expect(channel.kills, 0);
    },
  );

  test(
    'an unhashable result key loses the session',
    () async {
      final (session, channel) = await protoSession([
        answer([
          complete([
            pb.MontyNode(list: pb.Indexes()),
            pb.MontyNode(
              dict: pb.NodePairs(pairs: [pb.NodePair(key: 0, value: 0)]),
            ),
          ]),
        ]),
      ]);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            "invalid payload from worker: TypeError: unhashable type: 'list'",
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    },
  );

  test(
    'invalid datetime loses the session',
    () async {
      final (session, channel) = await protoSession([
        answer([
          complete([
            pb.MontyNode(
              datetime: pb.DateTime(year: 2026, month: 13, day: 1),
            ),
          ]),
        ]),
      ]);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: invalid value for DateTime.month: '
            '13 is outside the range 1..=12',
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedStart('42'), throwsStateError);
    },
  );

  test(
    'cyclic refusals send nothing and permit retry',
    () async {
      final (session, channel) = await protoSession([
        answer([protoInt(7)]),
        answer([protoCall()]),
        answer([protoInt(9)]),
      ]);
      final circular = throwsA(
        protoRuntime('ValueError', 'Circular reference detected'),
      );
      await expectLater(
        session.feedRun('x', inputs: {'x': protoCycle()}),
        circular,
      );
      expect(channel.requests, hasLength(1));
      expect(await session.feedRun('7'), const MontyInt(7));
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      expect(
        () => snapshot.resume(ExternalReturnValue(protoCycle())),
        circular,
      );
      expect(channel.requests, hasLength(3));
      final done = await snapshot.resume(
        const ExternalReturnValue(MontyInt(9)),
      );
      expect((done as MontyComplete).output, const MontyInt(9));
      expect(channel.requests, hasLength(4));
    },
  );

  for (final type in ['MemoryError', 'TimeoutError']) {
    test('print failure precedes $type', () async {
      final (session, _) = await protoSession([
        answer([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'x')]),
          raised(type, 'resource limit exceeded'),
        ]),
        answer([protoInt(42)]),
      ]);
      await expectLater(
        session.feedRun(
          'print("x")',
          printCallback: (_, _) =>
              throw const ExternalException('ValueError', 'print refused'),
        ),
        throwsA(protoRuntime('ValueError', 'print refused')),
      );
      expect(await session.feedRun('42'), const MontyInt(42));
    });
  }
}
