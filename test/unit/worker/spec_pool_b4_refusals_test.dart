// Input and manual-answer refusals are local and leave a corrected retry.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

Future<void> _refused(MontyValue value, Matcher error) async {
  final completed = answer([completeNone()]);
  final (session, channel) = await poolB2Session([
    answer([poolCall()]),
    completed,
    completed,
  ]);
  await expectLater(session.feedRun('x', inputs: {'x': value}), error);
  await expectLater(session.feedStart('x', inputs: {'x': value}), error);
  expect(channel.requests, hasLength(1));
  final snapshot = await session.feedStart('f()') as FunctionSnapshot;
  expect(() => snapshot.resume(ExternalReturnValue(value)), error);
  expect(channel.requests, hasLength(2));
  expect(snapshot.isSpent, isFalse);
  final done = await snapshot.resume(poolB2Answer) as MontyComplete;
  expect(done.output, const MontyNone());
  expect(await session.feedRun('None'), const MontyNone());
}

void main() {
  test(
    'REQ-MontyPath-21: surrogate path sends nothing and permits retry',
    () => _refused(
      MontyPath('\ud800'),
      throwsA(
        isA<MontyRuntimeError>()
            .having((e) => e.exception.excType, 'type', 'ValueError')
            .having(
              (e) => e.toString(),
              'text',
              "UnicodeEncodeError: 'utf-8' codec can't encode character "
                  r"'\ud800' in position 0: surrogates not allowed",
            ),
      ),
    ),
  );
  test(
    'REQ-MontySet-25: unhashable member sends nothing and permits retry',
    () => _refused(
      const MontySet([MontyList([])]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "TypeError: unhashable type: 'list'",
        ),
      ),
    ),
  );
  for (final offset in [-86400, 86400]) {
    test(
      'REQ-MontyTimeZone-17: offset $offset sends nothing and permits retry',
      () => _refused(MontyTimeZone(offsetSeconds: offset), throwsArgumentError),
    );
  }
}
