// Input and manual-answer refusals are local and leave a corrected retry.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

MontyFrozenSet _cycle() {
  final items = <MontyValue>[];
  final value = MontyFrozenSet(items);
  items.add(value);

  return value;
}

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
  final done = await snapshot.resume(poolB2Answer) as MontyComplete;
  expect(done.output, const MontyNone());
  expect(await session.feedRun('None'), const MontyNone());
}

void main() {
  test(
    'REQ-MontyFrozenSet-25: unhashable member sends nothing and permits retry',
    () => _refused(
      const MontyFrozenSet([MontyList([])]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "TypeError: unhashable type: 'list'",
        ),
      ),
    ),
  );
  test(
    'REQ-MontyFrozenSet-30: cyclic frozenset sends nothing and permits retry',
    () => _refused(
      _cycle(),
      throwsA(runtimePool('ValueError', 'Circular reference detected')),
    ),
  );
  for (final (label, value) in [
    ('days', const MontyTimeDelta(days: 1000000000, seconds: 0)),
    ('seconds', const MontyTimeDelta(days: 0, seconds: -1)),
    (
      'microseconds',
      const MontyTimeDelta(days: 0, seconds: 0, microseconds: 1000000),
    ),
  ]) {
    test(
      'REQ-MontyTimeDelta-17: invalid $label sends nothing and permits retry',
      () => _refused(value, throwsArgumentError),
    );
  }
}
